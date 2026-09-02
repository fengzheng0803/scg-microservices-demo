#!/usr/bin/env bash
# Task 8/12 验收：全架构压测（限流态 A + 容量态 B）
#
# 用法：
#   bash scripts/load-test.sh [a1|a2|b1|b2|b3|b4|b5|all] [探测并发档] [每档时长]
#   例：bash scripts/load-test.sh b4 "10 50 100" 15s
#   SEED_N=5000 bash scripts/load-test.sh b3   # env 覆盖播种量（默认 2000）
#
# 前置：bash scripts/launch-clients.sh（client-1..3 常驻）+ docker compose up -d nginx
#       （本脚本不自动拉起，职责分离）
#
# A 相位（限流态，默认 nginx 10/20 + SCG 40/40，验证限流器本身）：
#   A1 吞吐：每客户端 hey -z 30s -q 10 -c 1（总投递 30/s，应全部放行）
#   A2 并发洪水：hey -z 20s -c 20 无 -q（验证按 IP 拦截）
#
# B 相位（容量态，测量系统真实容量；限流不干预——阈值放大 100000/200000 永不拒绝，
#         但 lua/SCG 限流代码仍执行，测量路径含真实开销）：
#   b1 标定（列表接口压垮点探测）：逐级加压直到崩溃（错误率>0.5% / 5xx / P99>0.5s），
#      取崩溃点前一档 RPS 的 90% 为阈值，写 reports/capacity-threshold.json 的 list 节；
#      含直连 gateway 对照一档（量化 nginx 一跳代价）
#   b2 列表容量判定：读 list 阈值（缺则先跑 b1 探测），按崩溃前一档并发跑 30s，
#      断言 RPS ≥ 0.95×阈值 + 错误率≤0.5% + 5xx==0 + P99≤0.5s；含直连对照断言
#   b3 播种预热：API 创建 SEED_N 订单（userId=900001 标记），前 100 个为热 ID 逐个
#      GET 预热并验证 X-Cache: HIT；ID 列表落 reports/seed-state
#   b4 有缓存容量：100 热 ID 分客户端持续打 /orders/slow/{id}（命中即刷 Redis TTL，
#      HIT 不落库、不受 SLEEP 慢查询影响），压垮点探测 + 判定 + 抽查 100% HIT。
#      阈值写 capacity-threshold.json 的 hot 节
#   b5 无缓存容量：先经 Nacos 热切换 order.cache.enabled=false（Nacos 推送失败则用
#      docker-compose.nocache.yml override 重建 order-service 兜底，trap 恢复）。
#      打与 B4 完全相同的 100 热 ID 集与 /orders/slow/{id}（缓存关闭时每请求 MISS
#      落库，SQL 强制 SLEEP 50ms 模拟慢库——同 ID 集、同 hey 进程数、同梯度，保证
#      与 B4 的对比唯一变量是缓存开关），压垮点探测 + 判定 + 抽查 100% MISS。
#      阈值写 cold 节——三份探测结果（list/hot/cold）并排即缓存收益全景
#   b6 排队定位（两腿直连对照，同 B1 档位梯度）：腿1 直连 order-service（无 gateway 无
#      限流）；腿2 直连 gateway + X-Edge-RateLimited 头（模拟 nginx 注入，SCG 跳过限流
#      EVAL，只剩纯代理）。与 B1 压垮点对照判读排队层；与 b1 报告的 B1-direct（直连
#      gateway 不带头 = 代理+EVAL）三点对照拆分"纯代理"与"EVAL"两笔账。不改阈值文件
#
# 硬性红线：全程 [5xx] == 0（nginx/SCG 只允许 429 拒绝，不允许 5xx）。
# 错误口径：429 单独统计不计入错误；错误 = 5xx + 其他非 2xx 非 429 + 超时 + 连接失败。
# 目标 URL 必须是容器网络内服务名（禁止 localhost 起压——SNAT 坍缩单 IP）。
set -euo pipefail
cd "$(dirname "$0")/.."

# ---------- case 选择与参数 ----------

CASE="${1:-all}"
case "$CASE" in
    a1|a2|b1|b2|b3|b4|b5|b6|all) ;;
    *)
        echo "用法: bash scripts/load-test.sh [a1|a2|b1|b2|b3|b4|b5|b6|all] [探测并发档] [每档时长]" >&2
        exit 2
        ;;
esac

# 探测档位：每客户端并发（总并发 = ×3）。ARG 覆盖：逗号分隔（如 "25,50,100,200,300"）
if [ -n "${2:-}" ]; then PROBE_LEVELS=(${2//,/ }); else PROBE_LEVELS=(25 50 100 200 300 500); fi
PROBE_Z="${3:-20s}"
VERIFY_Z="30s"
SEED_N="${SEED_N:-2000}"
HOT_N=100
COLLAPSE_ERR=0.005          # 崩溃判据：任一客户端错误率
COLLAPSE_P99=0.5            # 崩溃判据（探测）：P99 上限（秒）
VERIFY_SEL_P99=0.3          # 判定档选择约束：候选档 P99 上限（给 0.5s 崩溃线留裕量）
VERIFY_P99=1.0              # 判定档 P99 上限（秒）：WSL2 共享宿主噪声大，判定用 1s 宽松线，
                            # 0.5s 是探测阶段的崩溃判据（曲线已定压垮点，判定重点是持续吞吐与零错误）
MAX_IDS_PER_CLIENT=40       # 防御上限：每客户端 hey 进程数。曾因冷 ID 池 633 个/客户端
                            # 起 1900 个 hey 进程击穿 WSL VM（b5 三次死于 c25 档的根因）
THRESHOLD_RATIO=0.9         # 阈值 = 崩溃前一档 RPS × 90%
VERIFY_RATIO=0.95           # 判定要求实测 RPS ≥ 阈值 × 95%（抖动余量）

URL='http://nginx/api/order/orders?page=1&size=1'
GATEWAY_URL='http://gateway:8080/api/order/orders?page=1&size=1'
NCLIENTS=3
# 宿主 CPU 核数：docker CPUPerc 是全核聚合口径（100% = 1 核满载），
# metrics_report 的饱和判据按此归一（旧 60% 阈值 ≈0.6 核，多核宿主上必误报）
HOST_NCPU=$(docker info --format '{{.NCPU}}' 2>/dev/null | grep -E '^[0-9]+$' || true)
[ -n "$HOST_NCPU" ] || HOST_NCPU=$(nproc || echo 4)
TS=$(date +%Y%m%d-%H%M%S)
mkdir -p reports
# 三件套报告（文件名带 case 名，TS 防重复运行覆盖）：
#   .txt  人读结果摘要——只含结论与关键数字，build_report 从日志抽取
#   .log  全量日志——hey 原始输出、容器重建细节
#   .json 结构化数字——每场景一行 RPS/P99/错误率/429/缓存，供程序消费（对比/画图）
BASE="reports/load-test-$CASE-$TS"
REPORT="$BASE.txt"
LOG="$BASE.log"
JSON="$BASE.json"
JSON_TMP="$JSON.tmp"
SEED_STATE="reports/seed-state"
THRESHOLD_FILE="reports/capacity-threshold.json"
: > "$LOG"
: > "$JSON_TMP"

fail() { echo "FAIL: $*" | tee -a "$LOG" >&2; exit 1; }
say()  { echo "$*" | tee -a "$LOG"; }

# build_report：从 LOG 抽取结果行生成 REPORT。只保留结论与关键数字：
# == 标题 / 通过 / FAIL / 警告 / 探测结论 / 合计行 / >>> 推断行 / 已生效恢复行。
# 由 cleanup（trap EXIT）统一生成——正常与失败退出路径报告都齐全
build_report() {
    grep -E '^(== |Phase 0 通过|FAIL|  >>> |  合计 |  [A-Z][0-9] 探测结论|.*(通过|已生效|已恢复|警告|报告：|容量阈值|判定档|记录（对照|结论|完成))' "$LOG" > "$REPORT" 2>/dev/null || true
}

# 轮询容器 healthcheck 直到 healthy（超时 180s）
wait_healthy() {
    local c t=0
    for c in "$@"; do
        until [ "$(docker inspect -f '{{.State.Health.Status}}' "$c" 2>/dev/null)" = "healthy" ]; do
            t=$((t + 3))
            [ "$t" -le 180 ] || fail "等待 $c healthy 超时（180s）"
            sleep 3
        done
        say "  $c healthy"
    done
}

# ---------- 清理 trap：B 相位放大重建 + 缓存禁用 都要恢复 ----------

TMP=$(mktemp -d)
B_AMPLIFIED=0
CACHE_DISABLED=0
CACHE_HOW=""
cleanup() {
    local rc=$?
    rm -rf "$TMP"
    rm -f "$JSON_TMP"   # 失败路径不会走到收尾的 JSON 组装，清掉 .tmp 残片
    if [ "$CACHE_DISABLED" = "1" ]; then
        say "== 恢复缓存配置（trap EXIT）=="
        cache_restore || say "警告：缓存配置恢复失败，请手动处理（Nacos enabled=true 或不带 override 重建）"
    fi
    if [ "$B_AMPLIFIED" = "1" ]; then
        say "== 恢复默认限流配置（trap EXIT：gateway Nacos 推回 40/40 + nginx 默认 env 重建）=="
        nacos_push_gateway 40 40 2>/dev/null || say "警告：gateway Nacos 恢复推送失败，请手动改 gateway.yaml"
        docker compose restart gateway >/dev/null 2>&1 || true
        if docker compose up -d --build nginx 2>&1 | tee -a "$LOG"; then
            wait_healthy nginx gateway 2>/dev/null || say "警告：恢复后未 healthy，请检查 docker compose ps"
        else
            say "警告：默认配置恢复失败，请手动执行 docker compose up -d --build nginx"
        fi
    fi
    build_report
    exit "$rc"
}
trap cleanup EXIT

# ---------- hey 输出解析（沿用 verify-ratelimit-clients.sh 的 awk 口径） ----------

# parse_status <output>：Status code distribution 段 → "2xx 429 5xx 其他 响应总数"
# 多个 hey 输出 concat 后可直接喂入：每段独立进入 section，计数跨段累加
parse_status() {
    printf '%s\n' "$1" | awk -F'[][\t ]+' '
        /Status code distribution:/ { in_section = 1; next }
        /Error distribution:/      { in_section = 0 }
        in_section && /^[[:space:]]*\[[0-9]+\]/ {
            total += $3
            if ($2 >= 200 && $2 < 300) twoxx += $3
            else if ($2 == 429) n429 += $3
            else if ($2 >= 500 && $2 < 600) n5xx += $3
            else other += $3
        }
        END { printf "%d %d %d %d %d\n", twoxx, n429, n5xx, other, total }
    '
}

# parse_status_detail <output>：逐状态码输出 "code:count ..."（供每客户端明细表）
parse_status_detail() {
    printf '%s\n' "$1" | awk -F'[][\t ]+' '
        /Status code distribution:/ { in_section = 1; next }
        /Error distribution:/      { in_section = 0 }
        in_section && /^[[:space:]]*\[[0-9]+\]/ { printf "%s:%d ", $2, $3 }
    '
}

# count_transport_errors <output>：Error distribution 段计数合计（超时/连接失败等传输层错误）
count_transport_errors() {
    printf '%s\n' "$1" | awk -F'[][\t ]+' '
        /Error distribution:/ { in_section = 1; next }
        in_section && /^[[:space:]]*\[[0-9]+\]/ { s += $2 }
        END { print s + 0 }
    '
}

# 求和/取 max 版（支持多 hey 输出 concat）：单 hey 输出下与单值版等价
extract_rps() { printf '%s\n' "$1" | awk '/Requests\/sec:/ { s += $2 } END { print s + 0 }'; }

# extract_p99 <output>：输出 "<值> <回退标记>"。优先取 99% 行最大值；99% 行全部缺失时
# （hey 单进程响应 <100 个会省略 99% 行——位置百分位需要第 100 个样本）回退取 95% 行，
# 回退标记=1。P99 ≥ P95 恒成立，回退值是真实 P99 的保守下界，报告打印处标注
extract_p99() {
    printf '%s\n' "$1" | awk '
        /Latency distribution:/ { in_dist = 1; next }
        in_dist && /^[[:space:]]*99% in / { if ($3 > m99) m99 = $3 }
        in_dist && /^[[:space:]]*95% in / { if ($3 > m95) m95 = $3 }
        END {
            if (m99 != "") print m99 + 0, 0
            else if (m95 != "") print m95 + 0, 1
            else print 0, 1
        }'
}

# ---------- 起压与统计 ----------

# 在 client-N 内跑 hey：输出追加进 TXT（完整日志），并分存 TMP/client-N.out 供解析
run_client() {
    local c=$1; shift
    docker exec "client-$c" hey "$@" 2>&1 | tee -a "$LOG" > "$TMP/client-$c.out" || true
}

# HEY_HDR：附加到 hey 的请求头（如 "X-Edge-RateLimited: 1"）。B6 腿2 的 gateway 带头
# 对照用——模拟 nginx 边缘层注入的头，让 SCG 兜底桶跳过限流 EVAL
HEY_HDR=""

# 并发在 client-1..N 上跑相同 hey 参数（起压目标 URL 由调用方作为最后一个参数传入）
parallel_hey() {
    local c
    for c in $(seq 1 "$NCLIENTS"); do
        if [ -n "$HEY_HDR" ]; then
            run_client "$c" -H "$HEY_HDR" "$@" &
        else
            run_client "$c" "$@" &
        fi
    done
    wait
}

out() { cat "$TMP/client-$1.out"; }

# 收集 client-1..3 指标到 CL_* 数组（每次 parallel_hey 后调用）
declare -a CL_RPS=() CL_P99=() CL_P99_FB=() CL_2XX=() CL_N429=() CL_5XX=() CL_OTHER=() CL_TOTAL=() CL_TRANS=()
collect() {
    local i j o two n4 n5 oth tot
    for i in $(seq 1 "$NCLIENTS"); do
        j=$((i - 1))
        o=$(out "$i")
        CL_RPS[$j]=$(extract_rps "$o")
        read -r CL_P99[$j] CL_P99_FB[$j] <<< "$(extract_p99 "$o")"
        [ -n "${CL_P99[$j]}" ] || fail "client-$i 无延迟分布行，无法计算 P99"
        read -r two n4 n5 oth tot <<< "$(parse_status "$o")"
        CL_2XX[$j]=$two; CL_N429[$j]=$n4; CL_5XX[$j]=$n5; CL_OTHER[$j]=$oth; CL_TOTAL[$j]=$tot
        CL_TRANS[$j]=$(count_transport_errors "$o")
    done
}

# client_error_rate <j>：该客户端错误率（错误=5xx+其他非2xx非429+传输层；429 不计）
client_error_rate() {
    local j=$1
    local e=$((CL_5XX[j] + CL_OTHER[j] + CL_TRANS[j]))
    local a=$((CL_TOTAL[j] + CL_TRANS[j]))
    if [ "$a" -gt 0 ]; then awk -v e="$e" -v a="$a" 'BEGIN { printf "%.4f", e/a }'; else echo "0.0000"; fi
}

# write_json_line <scenario> <entry> <concurrency> <rps> <p99> <error_rate> <n429> <cache> [per_ip_429]
# 注意：不要写 "${9:-{}}"——bash 对 :- 默认值的扫描在第一个裸 } 处终止，解析成
# "默认值={ 后跟字面 }"，$9 有值时输出凭空多一个 }（实测 JSON 全部损坏）。
# 调用方必须显式传第 9 参，无数据传 "{}"
write_json_line() {
    printf '{"scenario":"%s","entry":"%s","concurrency":%s,"rps":%s,"p99":%s,"error_rate":%s,"n429":%s,"cache":"%s","per_ip_429":%s}\n' \
        "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9" >> "$JSON_TMP"
}

# summarize <scenario> <entry> <concurrency> <cache>：汇总打印 + 写 JSON 行 + 红线 [5xx]==0
# 汇总结果存入全局：TOT_RPS / TOT_P99 / TOT_429 / TOT_5XX / TOT_ERR
summarize() {
    local scenario=$1 entry=$2 concurrency=$3 cache=${4:-"-"}
    local i j ip429="" rps_sum=0 p99_max=0 nerr=0
    TOT_RPS=0; TOT_P99=0; TOT_P99_FB=0; TOT_429=0; TOT_5XX=0; TOT_ATTEMPTS=0
    for i in $(seq 1 "$NCLIENTS"); do
        j=$((i - 1))
        rps_sum=$(awk -v s="$rps_sum" -v r="${CL_RPS[$j]}" 'BEGIN { print s + r }')
        p99_max=$(awk -v m="$p99_max" -v p="${CL_P99[$j]}" 'BEGIN { if (p > m) print p; else print m }')
        TOT_P99_FB=$((TOT_P99_FB + CL_P99_FB[j]))
        TOT_ATTEMPTS=$((TOT_ATTEMPTS + CL_TOTAL[j] + CL_TRANS[j]))
        TOT_429=$((TOT_429 + CL_N429[j]))
        TOT_5XX=$((TOT_5XX + CL_5XX[j]))
        nerr=$((nerr + CL_5XX[j] + CL_OTHER[j] + CL_TRANS[j]))
        ip429="$ip429\"client-$i\":${CL_N429[$j]}"
        [ "$i" -lt "$NCLIENTS" ] && ip429="$ip429,"
    done
    TOT_RPS=$rps_sum
    TOT_P99=$p99_max
    TOT_ERR=$(awk -v e="$nerr" -v a="$TOT_ATTEMPTS" 'BEGIN { if (a > 0) printf "%.4f", e/a; else print "0.0000" }')
    if [ "$TOT_P99_FB" -gt 0 ]; then
        say "  合计 RPS=$TOT_RPS  P99≥${TOT_P99}s（99% 行缺失回退 95% 下界）  请求=$TOT_ATTEMPTS  429=$TOT_429  5xx=$TOT_5XX  错误率=$TOT_ERR"
    else
        say "  合计 RPS=$TOT_RPS  P99(max)=${TOT_P99}s  请求=$TOT_ATTEMPTS  429=$TOT_429  5xx=$TOT_5XX  错误率=$TOT_ERR"
    fi
    write_json_line "$scenario" "$entry" "$concurrency" "$TOT_RPS" "$TOT_P99" "$TOT_ERR" "$TOT_429" "$cache" "{$ip429}"
    [ "$TOT_5XX" -eq 0 ] || fail "$scenario 出现 $TOT_5XX 次 5xx（硬性红线）"
}

# per_client_detail：打印每客户端明细（发送数=状态响应+传输错误；收到数=状态响应合计）
per_client_detail() {
    local i j sent
    for i in $(seq 1 "$NCLIENTS"); do
        j=$((i - 1))
        sent=$((CL_TOTAL[j] + CL_TRANS[j]))
        say "  client-$i: 发送=$sent 收到=${CL_TOTAL[$j]} 传输错误=${CL_TRANS[$j]} 状态码[$(parse_status_detail "$(out "$i")")]"
    done
}

# ---------- Phase 0 前置检查（不自动拉起，职责分离） ----------

phase0() {
    say "== Phase 0 前置检查 =="
    for i in $(seq 1 "$NCLIENTS"); do
        docker inspect "client-$i" >/dev/null 2>&1 \
            || fail "client-$i 不存在，请先运行 bash scripts/launch-clients.sh"
    done
    docker inspect nginx >/dev/null 2>&1 \
        || fail "nginx 未运行，请先 docker compose up -d nginx"
    for i in $(seq 1 "$NCLIENTS"); do
        CODE=$(docker exec "client-$i" curl -s -o /dev/null -w '%{http_code}' "$URL")
        [ "$CODE" = "200" ] || fail "client-$i 冒烟请求返回 $CODE（应为 200）"
    done
    say "Phase 0 通过：client-1..3 与 nginx 就绪，冒烟全 200"
    sleep 2
}

# ---------- A 相位（限流态：默认配置 nginx 10/20 + SCG 40/40） ----------

run_a1() {
    say "== A1 吞吐：每客户端 hey -z 30s -q 10 -c 1（总投递 30/s，应全部放行）=="
    parallel_hey -z 30s -q 10 -c 1 "$URL"
    collect
    for i in $(seq 1 "$NCLIENTS"); do
        j=$((i - 1))
        awk -v r="${CL_RPS[$j]}" 'BEGIN { exit !(r >= 9.5 && r <= 11.5) }' \
            || fail "A1 client-$i RPS=${CL_RPS[$j]} 超出 [9.5, 11.5]"
    done
    summarize A1 nginx 3
    awk -v r="$TOT_RPS" 'BEGIN { exit !(r >= 27) }' || fail "A1 合计 RPS=$TOT_RPS 应 ≥ 27"
    [ "$TOT_429" -le 10 ] || fail "A1 [429]=$TOT_429 应 ≤ 10（首秒 SCG 突发边缘裕量）"
    say "A1 通过：每客户端 RPS ∈ [9.5,11.5]，合计 $TOT_RPS ≥ 27，[429]=$TOT_429 ≤ 10"
    sleep 2
}

run_a2() {
    say "== A2 并发洪水：每客户端 hey -z 20s -c 20（验证按 IP 拦截）=="
    parallel_hey -z 20s -c 20 "$URL"
    collect
    say "== A2 每客户端明细 =="
    per_client_detail
    for i in $(seq 1 "$NCLIENTS"); do
        j=$((i - 1))
        n=${CL_N429[$j]}; t=${CL_TOTAL[$j]}
        awk -v n="$n" -v t="$t" 'BEGIN { exit !(t > 0 && n/t >= 0.8) }' \
            || fail "A2 client-$i [429]=$n 占响应 $t 的比例应 ≥ 80%（按 IP 拦截不足）"
    done
    summarize A2 nginx 60
    say "A2 通过：3 客户端各有独立 429 且占比 ≥ 80%（压测下按 IP 分桶仍成立）"
    sleep 2
}

# ---------- B 相位（容量态：限流阈值放大到系统摸不到的高度，永不拒绝） ----------

b_phase_up() {
    [ "$B_AMPLIFIED" = "1" ] && return
    say "== B 相位（容量态：nginx env 放大重建 + gateway Nacos 放大推配置重启）=="
    say "--- 放大：RATE_LIMIT_RPS=100000 RATE_LIMIT_CAP=200000（nginx env），scg.rate-limit 100000/200000（gateway Nacos）"
    RATE_LIMIT_RPS=100000 RATE_LIMIT_CAP=200000 \
        docker compose up -d --build nginx 2>&1 | tee -a "$LOG" || fail "nginx 放大重建失败"
    nacos_push_gateway 100000 200000 || fail "gateway Nacos 放大推送失败"
    docker compose restart gateway >/dev/null 2>&1 || fail "gateway 重启失败"
    B_AMPLIFIED=1
    wait_healthy nginx gateway
    say "  证据：nginx RATE=$(docker exec nginx sh -c 'echo $RATE_LIMIT_RPS/$RATE_LIMIT_CAP')，gateway Nacos $(nacos_get_gateway_rate)"
    CODE=$(docker exec client-1 curl -s -o /dev/null -w '%{http_code}' "$URL")
    [ "$CODE" = "200" ] || fail "放大重建后冒烟请求返回 $CODE（应为 200）"
    say "  放大后冒烟通过"
    sleep 2
}

# ---------- Nacos 配置推送（缓存开关） ----------

# nacos_push_to <dataId> <yaml正文>：登录 + 推任意 dataId 的配置。成功 0，失败非 0
nacos_push_to() {
    local dataId=$1 content=$2 token
    token=$(docker exec client-1 sh -c 'curl -s -m 5 -X POST "http://nacos:8848/nacos/v1/auth/login" -d "username=nacos&password=nacos"' 2>/dev/null \
        | sed -n 's/.*"accessToken":"\([^"]*\)".*/\1/p')
    [ -n "$token" ] || return 1
    # 注意：content 必须带真实换行（printf 生成）；字面 \n 会让 YAML 解析失败
    docker exec client-1 sh -c "curl -s -m 10 -X POST 'http://nacos:8848/nacos/v1/cs/configs' \
        --data-urlencode 'dataId=$dataId' --data-urlencode 'group=DEFAULT_GROUP' \
        --data-urlencode 'content=$content' --data-urlencode 'accessToken=$token'" 2>/dev/null | grep -q '^true$'
}

# nacos_push <yaml正文>：推 order-service.yaml（缓存开关等），nacos_push_to 的便捷包装
nacos_push() { nacos_push_to order-service.yaml "$1"; }

# nacos_gateway_yaml <rate> <burst>：gateway.yaml 正文（保留 logging 段）
nacos_gateway_yaml() {
    printf 'logging:\n  level:\n    org.springframework.cloud.gateway: INFO\nscg:\n  rate-limit:\n    replenish-rate: %s\n    burst-capacity: %s' "$1" "$2"
}

# nacos_push_gateway <rate> <burst>：推 gateway.yaml 的 scg.rate-limit（gateway 重启生效）
nacos_push_gateway() { nacos_push_to gateway.yaml "$(nacos_gateway_yaml "$1" "$2")"; }

# nacos_get_gateway_rate：读回 gateway.yaml 的 rate/burst 供证据行显示
nacos_get_gateway_rate() {
    local token
    token=$(docker exec client-1 sh -c 'curl -s -m 5 -X POST "http://nacos:8848/nacos/v1/auth/login" -d "username=nacos&password=nacos"' 2>/dev/null \
        | sed -n 's/.*"accessToken":"\([^"]*\)".*/\1/p')
    docker exec client-1 sh -c "curl -s -m 5 'http://nacos:8848/nacos/v1/cs/configs?dataId=gateway.yaml&group=DEFAULT_GROUP&accessToken=$token'" 2>/dev/null \
        | grep -oE '(replenish-rate|burst-capacity): [0-9]+' | awk -F': ' '{printf "%s=%s ", $1, $2}'
}

# nacos_cache_yaml <enabled>：输出 order-service.yaml 正文（保持 ttl/max-size 不变）
nacos_cache_yaml() {
    printf 'order:\n  cache:\n    enabled: %s\n    ttl: 10s\n    max-size: 100' "$1"
}

# cache_probe <expect>：连续请求已缓存过的 ID，expect=hit 期望第二次 HIT，expect=miss 期望全 MISS
cache_probe() {
    local expect=$1 id=$(docker exec mysql-order sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" order_db -N -e "SELECT id FROM orders LIMIT 1;" 2>/dev/null')
    local h1 h2
    h1=$(docker exec client-1 curl -s -o /dev/null -D - "http://nginx/api/order/orders/$id" | grep -io "x-cache: [a-z]*" | awk '{print $2}')
    h2=$(docker exec client-1 curl -s -o /dev/null -D - "http://nginx/api/order/orders/$id" | grep -io "x-cache: [a-z]*" | awk '{print $2}')
    case "$expect" in
        hit)  [ "$h2" = "HIT" ];;
        miss) [ "$h1" = "MISS" ] && [ "$h2" = "MISS" ];;
    esac
}

# cache_disable：Nacos 热切换优先；失败走 override 重建兜底。置 CACHE_DISABLED/CACHE_HOW
cache_disable() {
    say "== 关闭缓存（Nacos 热切换 order.cache.enabled=false，优先）=="
    if nacos_push "$(nacos_cache_yaml false)"; then
        sleep 8
        if cache_probe miss; then
            CACHE_DISABLED=1; CACHE_HOW=nacos
            say "  已生效（Nacos 热切换，无需重建）：连续请求全 MISS"
            return 0
        fi
        say "  Nacos 推送成功但应用未切换（可能被更高优先级属性覆盖），改用重建兜底"
    else
        say "  Nacos 推送失败（服务未部署或认证异常），改用重建兜底"
    fi
    say "--- 重建兜底：docker compose -f docker-compose.yml -f docker-compose.nocache.yml up -d --build order-service"
    docker compose -f docker-compose.yml -f docker-compose.nocache.yml up -d --build order-service 2>&1 | tee -a "$LOG" \
        || fail "nocache override 重建失败"
    wait_healthy order-service
    cache_probe miss || fail "重建后缓存仍命中（ORDER_CACHE_ENABLED=false 未生效）"
    CACHE_DISABLED=1; CACHE_HOW=rebuild
    say "  已生效（override 重建）：连续请求全 MISS"
}

# cache_restore：按关闭方式恢复（trap 与 b5 结束共用）
cache_restore() {
    [ "$CACHE_DISABLED" = "1" ] || return 0
    case "$CACHE_HOW" in
        nacos)
            say "--- 恢复缓存：Nacos 推回 enabled=true"
            nacos_push "$(nacos_cache_yaml true)" || return 1
            sleep 8
            ;;
        rebuild)
            say "--- 恢复缓存：不带 override 重建 order-service"
            docker compose up -d --build order-service 2>&1 | tee -a "$LOG" || return 1
            wait_healthy order-service
            ;;
    esac
    cache_probe hit || { say "警告：恢复后缓存未命中（TTL 内应 HIT）"; return 1; }
    CACHE_DISABLED=0; CACHE_HOW=""
    say "  缓存已恢复（连续请求第 2 次 HIT）"
}

# ---------- 阈值文件 ----------

# update_threshold <label> <threshold> <collapse_level> <verify_c> <direct_rps> <direct_p99>
update_threshold() {
    python3 - "$THRESHOLD_FILE" "$TS" "$@" <<'PY'
import json, sys
path, ts, label, thr, collapse, verify_c, drps, dp99 = sys.argv[1], sys.argv[2], sys.argv[3], \
    float(sys.argv[4]), int(sys.argv[5]), int(sys.argv[6]), sys.argv[7], sys.argv[8]
def num(s):
    return None if s in ("", "None") else float(s)
try:
    d = json.load(open(path))
except Exception:
    d = {}
d["generated_at"] = ts
d[label] = {"threshold_rps": thr, "collapse_level": collapse, "verify_c": verify_c,
            "direct_rps": num(drps), "direct_p99": num(dp99)}
json.dump(d, open(path, "w"), indent=2)
PY
}

# read_threshold <label>：输出阈值 RPS（无则空）
read_threshold() {
    python3 -c "import json;d=json.load(open('$THRESHOLD_FILE')).get('$1',{});print(d.get('threshold_rps',''))" 2>/dev/null
}

# read_verify_c <label>：输出判定档每客户端并发（无则空）
read_verify_c() {
    python3 -c "import json;d=json.load(open('$THRESHOLD_FILE')).get('$1',{});print(d.get('verify_c',''))" 2>/dev/null
}

# read_collapse <label>：输出压垮点档位（无则空）
read_collapse() {
    python3 -c "import json;d=json.load(open('$THRESHOLD_FILE')).get('$1',{});print(d.get('collapse_level',''))" 2>/dev/null
}

# ---------- 播种（b3）与点查路径打流 ----------

run_b3() {
    b_phase_up
    say "== B3 播种预热：API 创建 $SEED_N 订单 + 前 $HOT_N 个热 ID 预热 =="
    local stored n
    stored=$(sed -n '1p' "$SEED_STATE" 2>/dev/null | awk '{print $2}')
    if [ "$stored" = "$SEED_N" ] && [ "$(wc -l < "$SEED_STATE")" -ge $((SEED_N + 2)) ]; then
        say "--- seed-state 已存在（$stored 单），复用不重复播种"
    else
        say "--- 经 nginx POST $SEED_N 个订单（userId=900001 标记，16 并发）"
        docker exec client-1 sh -c "seq 1 $SEED_N | xargs -P 16 -I{} curl -s -m 15 -X POST http://nginx/api/order/orders \
            -H 'Content-Type: application/json' -d '{\"userId\":900001,\"productName\":\"seed-{}\",\"amount\":10.00}' \
            | grep -o '\"id\":[0-9]*' | cut -d: -f2" > "$TMP/seed-ids.txt"
        n=$(wc -l < "$TMP/seed-ids.txt")
        [ "$n" -eq "$SEED_N" ] || fail "播种创建 $n/$SEED_N 个订单（不足，可能被限流或写入失败）"
        # 状态文件：前两行元信息，之后每行一个 ID（前 HOT_N 行是热 ID）
        { echo "SEED_N $SEED_N"; echo "HOT_N $HOT_N"; cat "$TMP/seed-ids.txt"; } > "$SEED_STATE"
        say "  播种完成：$n 个订单，ID 列表落 $SEED_STATE"
    fi
    say "--- 预热前 $HOT_N 个热 ID（每 ID 两次 GET：第一次落缓存，第二次验证 HIT）"
    local hit=0 id h
    while read -r id; do
        # 第一次 GET：MISS 并把结果写进 Redis（@Cacheable put）
        docker exec client-1 curl -s -o /dev/null "http://nginx/api/order/orders/$id"
        # 第二次 GET：应 HIT。grep 无匹配返回非 0，set -e 下需 || true
        h=$(docker exec client-1 curl -s -o /dev/null -D - "http://nginx/api/order/orders/$id" | grep -io "x-cache: hit" || true)
        [ -n "$h" ] && hit=$((hit + 1))
    done < <(sed -n "3,$((HOT_N + 2))p" "$SEED_STATE")
    [ "$hit" -eq "$HOT_N" ] || fail "预热 $hit/$HOT_N 个热 ID 命中（缓存异常）"
    say "B3 通过：$hit 个热 ID 全部 HIT"
    sleep 2
}

# seed_ids <mode> <client>：该客户端分到的 ID 列表（空格分隔）。当前仅 hot 段被使用
# （b4/b5 同集对比），seed-state 中热段之后的冷 ID 保留为数据备查
seed_ids() {
    local mode=$1 c=$2 total per start end
    total=$HOT_N
    per=$(( (total + NCLIENTS - 1) / NCLIENTS ))
    start=$(( 3 + (c - 1) * per ))
    end=$(( start + per - 1 ))
    [ "$end" -gt $((HOT_N + 2)) ] && end=$((HOT_N + 2))
    [ "$start" -le "$end" ] && sed -n "${start},${end}p" "$SEED_STATE" | tr '\n' ' '
}

# run_multi_ids <mode> <client> <每客户端总并发> <时长>：把该客户端的 ID 段拆成多个 hey 并行打，
# 输出合并进 TMP/client-N.out（parse/extract 的求和版函数已支持 concat 多 hey 输出）。
# 打的是慢库模拟端点 /orders/slow/{id}（与 get 共享缓存：HIT 无 SLEEP，MISS 落库 SLEEP 50ms）
run_multi_ids() {
    local mode=$1 c=$2 cp=$3 z=$4 ids id i=0 per
    ids=$(seed_ids "$mode" "$c")
    # 防御上限：hey 进程数按 ID 数起，超大 ID 池会进程爆炸击穿宿主机（实测教训）
    ids=$(echo "$ids" | cut -d' ' -f1-"$MAX_IDS_PER_CLIENT")
    local n_ids
    n_ids=$(echo "$ids" | wc -w)
    [ "$n_ids" -gt 0 ] || fail "client-$c 在 $mode 段无 ID（seed-state 缺失？请先跑 b3）"
    per=$(( (cp + n_ids - 1) / n_ids ))
    [ "$per" -lt 1 ] && per=1
    for id in $ids; do
        i=$((i + 1))
        ( docker exec "client-$c" hey -z "$z" -c "$per" "http://nginx/api/order/orders/slow/$id" 2>&1 \
            | tee -a "$LOG" > "$TMP/client-$c-m$i.out" ) &
    done
    wait
    cat "$TMP"/client-$c-m*.out > "$TMP/client-$c.out" 2>/dev/null
    rm -f "$TMP"/client-$c-m*.out
}

# parallel_multi <mode> <每客户端并发> <时长>：3 客户端各自按 ID 段多 hey 并行
parallel_multi() {
    local mode=$1 cp=$2 z=$3 c
    for c in $(seq 1 "$NCLIENTS"); do
        run_multi_ids "$mode" "$c" "$cp" "$z" &
    done
    wait
}

# ---------- 分段指标采集与瓶颈推断 ----------

# dur_secs "20s" -> 20
dur_secs() { echo "${1%s}"; }

# metrics_sampler <tag> <secs>：后台每 2s 采样一次 docker stats（CPU/MEM/NetIO/BlockIO）
# 由调用方在起压前启动，起压函数内部的 wait 会一并等待其自然结束
metrics_sampler() {
    local tag=$1 secs=$2 end
    end=$(( $(date +%s) + secs + 3 ))
    : > "$TMP/metrics-$tag.log"
    while [ "$(date +%s)" -lt "$end" ]; do
        docker stats --no-stream --format '{{.Name}}|{{.CPUPerc}}|{{.MemPerc}}|{{.NetIO}}|{{.BlockIO}}' 2>/dev/null \
            >> "$TMP/metrics-$tag.log"
        sleep 2
    done
}

# metrics_report <tag> <scenario>：打印每容器分段指标（avg CPU/MEM + 末次 NetIO/BlockIO），
# 写 JSON 行 <scenario>-metrics，并给出瓶颈推断
metrics_report() {
    local tag=$1 scenario=$2 top tk maxv
    [ -s "$TMP/metrics-$tag.log" ] || return 0
    say "  -- $scenario 分段指标 --"
    awk -F'|' -v SCN="$scenario" -v NCPU="$HOST_NCPU" -v jsonfile="$TMP/metrics-$tag.json" '
    { split($2, c, "%"); split($3, m, "%"); cpu[$1] += c[1]; mem[$1] += m[1]; n[$1]++; net[$1] = $4; blk[$1] = $5 }
    END {
        first = 1
        json = "{\"scenario\":\"" SCN "-metrics\",\"containers\":{"
        for (k in n) {
            printf "     %-15s CPU %5.1f%% (%4.1f/%d核)  MEM %5.1f%%  NetIO %s  BlkIO %s\n", k, cpu[k]/n[k], cpu[k]/n[k]/100, NCPU, mem[k]/n[k], net[k], blk[k]
            if (!first) json = json ","
            first = 0
            json = json "\"" k "\":{\"cpu\":" sprintf("%.1f", cpu[k]/n[k]) ",\"mem\":" sprintf("%.1f", mem[k]/n[k]) "}"
        }
        json = json "}}"
        print json > jsonfile
    }' "$TMP/metrics-$tag.log" | tee -a "$LOG"
    cat "$TMP/metrics-$tag.json" >> "$JSON_TMP"
    # 瓶颈推断：docker CPUPerc 是全核聚合口径（100% = 1 核满载），饱和判据必须按核数
    # 归一——饱和线 = 80% × 宿主核数（14 核 → 1120%）。旧判据 60% ≈ 0.6 核，任何多核
    # 宿主都会误报"打满"。排队资源（Tomcat 线程池、Hikari 连接池、accept 队列等，
    # 现经 Nacos order-service.yaml 配置，重启生效）docker stats 看不见。实测：200 线程
    # 时 B1 峰值 ~3.7-4.1k（线程池节流）；threads.max=400 后峰值 +22% 到 ~4.5k 且压垮点
    # 从 c=500 提前到 c=300——下一层（MySQL filesort 争用）接管，瓶颈是分层转移而非单一。
    read -r t1 v1 t2 v2 rv tot <<< "$(awk -F'|' '
        { split($2, c, "%"); cpu[$1] += c[1]; n[$1]++ }
        END {
            for (k in n) { v = cpu[k]/n[k]; tot += v; if (v > v1) { v2 = v1; t2 = t1; v1 = v; t1 = k } else if (v > v2) { v2 = v; t2 = k } }
            rv = (n["redis"] ? cpu["redis"]/n["redis"] : 0)
            printf "%s %.1f %s %.1f %.1f %.1f", t1, v1, t2, v2, rv, tot
        }' "$TMP/metrics-$tag.log")"
    verdict_for() {
        case "$1" in
            mysql-order)   echo "MySQL（列表接口全表扫描 filesort，建议 create_time 加索引）" ;;
            order-service) echo "order-service JVM（Tomcat 线程 + MyBatis/JSON 处理）" ;;
            gateway)       echo "SCG 过滤链（每请求 Redis EVAL 限流开销）" ;;
            nginx)         echo "nginx 边缘层（lua 限流 EVAL + 代理转发）" ;;
            redis)         echo "Redis（单线程命令吞吐）" ;;
            *)             echo "$1" ;;
        esac
    }
    cores() { awk -v v="$1" 'BEGIN { printf "%.1f", v / 100 }'; }
    SAT_LINE=$(awk -v n="$HOST_NCPU" 'BEGIN { printf "%.0f", n * 100 * 0.8 }')
    if awk -v t="$tot" -v s="$SAT_LINE" 'BEGIN { exit !(t >= s) }'; then
        say "  >>> 瓶颈推断：宿主机级 CPU 饱和（容器合计 ${tot}% ≈ $(cores "$tot") 核/${HOST_NCPU} 核，饱和线 ${SAT_LINE}%）——主贡献 $(verdict_for "$t1")（${v1}%）+ $(verdict_for "$t2")（${v2}%）"
    else
        say "  >>> 瓶颈推断：CPU 未饱和（容器合计 ${tot}% ≈ $(cores "$tot") 核/${HOST_NCPU} 核，最高 $t1 ${v1}%）——瓶颈在排队资源（Tomcat 线程池、Hikari 连接池、accept 队列等，docker stats 不可见）、IO 或链路往返"
    fi
    # Redis 例外：单线程执行模型，~100%（1 核）即饱和，与核数归一无关
    awk -v r="$rv" 'BEGIN { exit !(r >= 90) }' \
        && say "  >>> 附加预警：Redis 单线程 CPU ${rv}%（单线程执行模型 ~1 核即饱和——每请求 2 次限流 EVAL 的往返开销不可忽视）" \
        || true   # set -e 下 && 短路失败会杀脚本，必须显式兜底
}

# summarize_overload <scenario> <entry> <concurrency> <cache>：过载观察档专用汇总——
# 豁免 [5xx]==0 红线（故意诱发超载，5xx 是观察对象），打印峰值后行为结论
summarize_overload() {
    local scenario=$1 entry=$2 concurrency=$3 cache=${4:-"-"}
    local i j nerr=0 rps_sum=0 p99_max=0
    TOT_ATTEMPTS=0; TOT_P99_FB=0; TOT_429=0; TOT_5XX=0
    for i in $(seq 1 "$NCLIENTS"); do
        j=$((i - 1))
        rps_sum=$(awk -v s="$rps_sum" -v r="${CL_RPS[$j]}" 'BEGIN { print s + r }')
        p99_max=$(awk -v m="$p99_max" -v p="${CL_P99[$j]}" 'BEGIN { if (p > m) print p; else print m }')
        TOT_P99_FB=$((TOT_P99_FB + CL_P99_FB[j]))
        TOT_ATTEMPTS=$((TOT_ATTEMPTS + CL_TOTAL[j] + CL_TRANS[j]))
        TOT_429=$((TOT_429 + CL_N429[j]))
        TOT_5XX=$((TOT_5XX + CL_5XX[j]))
        nerr=$((nerr + CL_5XX[j] + CL_OTHER[j] + CL_TRANS[j]))
    done
    TOT_RPS=$rps_sum; TOT_P99=$p99_max
    TOT_ERR=$(awk -v e="$nerr" -v a="$TOT_ATTEMPTS" 'BEGIN { if (a > 0) printf "%.4f", e/a; else print "0.0000" }')
    if [ "$TOT_P99_FB" -gt 0 ]; then
        say "  $scenario 过载观察（红线豁免档）：RPS=$TOT_RPS  P99≥${TOT_P99}s（99% 行缺失回退 95% 下界）  429=$TOT_429  5xx=$TOT_5XX  错误率=$TOT_ERR"
    else
        say "  $scenario 过载观察（红线豁免档）：RPS=$TOT_RPS  P99(max)=${TOT_P99}s  429=$TOT_429  5xx=$TOT_5XX  错误率=$TOT_ERR"
    fi
    per_client_detail
    local verdict
    if [ "$TOT_5XX" -gt 0 ]; then
        verdict="出现 $TOT_5XX 次 5xx——超载已达服务崩溃/超时层级"
    elif awk -v e="$TOT_ERR" 'BEGIN { exit !(e > 0.005) }'; then
        verdict="无 5xx 但错误率=$TOT_ERR（连接失败/超时增多——socket 或连接池层级过载）"
    elif [ "$TOT_429" -gt 0 ]; then
        verdict="出现 $TOT_429 次 429——限流拒绝兜底生效"
    else
        verdict="无错误无拒绝：请求排队，延迟上升（P99=${TOT_P99}s），吞吐饱和/回落——优雅降级"
    fi
    say "  >>> 峰值后行为：$verdict"
    write_json_line "$scenario" "$entry" "$concurrency" "$TOT_RPS" "$TOT_P99" "$TOT_ERR" "$TOT_429" "$cache" "{}"
}

# ---------- 压垮点探测与容量判定 ----------

# 崩溃判据：任一客户端错误率超限 / 5xx / P99 超限
is_collapse() {
    local j
    for j in 0 1 2; do
        awk -v e="$(client_error_rate "$j")" -v m="$COLLAPSE_ERR" 'BEGIN { exit !(e <= m) }' || return 0
    done
    [ "$TOT_5XX" -gt 0 ] && return 0
    awk -v p="$TOT_P99" -v m="$COLLAPSE_P99" 'BEGIN { exit !(p <= m) }' || return 0
    return 1
}

# probe_capacity <mode> <label>：逐级加压找压垮点，写曲线行；全局 PROBE_THRESHOLD/
# PROBE_COLLAPSE_LEVEL/PROBE_VERIFY_C 输出阈值与判定档。mode: list|hot|cold
PROBE_THRESHOLD=0; PROBE_COLLAPSE_LEVEL=0; PROBE_VERIFY_C=0; PROBE_PREV_RPS=0; PROBE_PREV_P99=0; PROBE_PREV_C=0
declare -a LV_C=() LV_RPS=() LV_P99=()
probe_capacity() {
    local mode=$1 label=$2 cache_tag=${3:-$1} url=${4:-$URL} c prev_rps=0 prev_c=0 prev2_c=0 collapse_level=0 i=0 idx
    PROBE_THRESHOLD=0; PROBE_COLLAPSE_LEVEL=0; PROBE_VERIFY_C=0; PROBE_PREV_RPS=0; PROBE_PREV_P99=0; PROBE_PREV_C=0
    LV_C=(); LV_RPS=(); LV_P99=()
    say "== $label 压垮点探测（每客户端并发 ${PROBE_LEVELS[*]}，每档 $PROBE_Z）=="
    for c in "${PROBE_LEVELS[@]}"; do
        say "--- $label-c$c：总并发 $((c * NCLIENTS))（每客户端 -c $c，$PROBE_Z）"
        metrics_sampler "$label-c$c" "$(dur_secs "$PROBE_Z")" &
        if [ "$mode" = list ]; then
            parallel_hey -z "$PROBE_Z" -c "$c" "$url"
        else
            parallel_multi "$mode" "$c" "$PROBE_Z"
        fi
        collect
        summarize "$label-c$c" nginx "$((c * NCLIENTS))" "$cache_tag"
        metrics_report "$label-c$c" "$label-c$c"
        if is_collapse; then
            collapse_level=$c
            say "  >>> $label-c$c 崩溃（错误率>${COLLAPSE_ERR} 或 5xx 或 P99>${COLLAPSE_P99}s），压垮点=$c"
            break
        fi
        prev2_c=$prev_c; prev_c=$c; prev_rps=$TOT_RPS
        # 未崩溃档记录为判定档候选（后续按 P99 约束取 RPS 最高档）
        LV_C[$i]=$c; LV_RPS[$i]=$TOT_RPS; LV_P99[$i]=$TOT_P99; i=$((i + 1))
        # 崩溃前一档的 nginx 数字（入口对照用同并发档比较，不可用崩溃档的劣化数字）
        PROBE_PREV_RPS=$TOT_RPS; PROBE_PREV_P99=$TOT_P99; PROBE_PREV_C=$c
        sleep 2
    done
    if [ "$collapse_level" -eq 0 ]; then
        say "  >>> 所有档位均未崩溃，取末档 $prev_c 为容量上界（可加大探测档位）"
        collapse_level=$prev_c
    fi
    # 注意：RPS 是浮点（如 4509.16），整数比较 [ x -gt 0 ] 会报错，必须用 awk
    awk -v r="$prev_rps" 'BEGIN { exit !(r > 0) }' || fail "$label 探测无有效数据（第一档即崩溃？请检查环境）"
    PROBE_THRESHOLD=$(awk -v r="$prev_rps" -v k="$THRESHOLD_RATIO" 'BEGIN { printf "%.0f", r * k }')
    PROBE_COLLAPSE_LEVEL=$collapse_level
    # 判定档选择（混合判据）：P99 ≤ VERIFY_SEL_P99（0.3s，给 0.5s 崩溃线留裕量）的
    # 未崩溃档中取 RPS 最高者——贴着真实峰值且远离 P99 临界区。裸取全曲线 RPS 最高档
    # 不行：饱和区 RPS 平坦（±5%），峰值档是噪声选的；旧"退两档"固定规则受档位间隔
    # 影响。无候选档（如各档 P99 均贴近临界）时兜底退两档
    PROBE_VERIFY_C=0; PROBE_VERIFY_RPS=0
    for idx in $(seq 0 $((i - 1))); do
        awk -v p="${LV_P99[$idx]}" -v m="$VERIFY_SEL_P99" 'BEGIN { exit !(p <= m) }' || continue
        awk -v r="${LV_RPS[$idx]}" -v b="$PROBE_VERIFY_RPS" 'BEGIN { exit !(r > b) }' || continue
        PROBE_VERIFY_C=${LV_C[$idx]}; PROBE_VERIFY_RPS=${LV_RPS[$idx]}
    done
    if [ "$PROBE_VERIFY_C" -gt 0 ]; then
        say "  判定档选择：P99≤${VERIFY_SEL_P99}s 约束下 RPS 最高档 c=$PROBE_VERIFY_C（RPS=$PROBE_VERIFY_RPS）"
    else
        PROBE_VERIFY_C=$prev2_c
        [ "$PROBE_VERIFY_C" -gt 0 ] || PROBE_VERIFY_C=$prev_c
        say "  判定档选择：无 P99≤${VERIFY_SEL_P99}s 的档位，兜底退两档 c=$PROBE_VERIFY_C"
    fi
    say "  $label 探测结论：压垮点=$collapse_level，崩溃前 RPS=$prev_rps，阈值=90%=$PROBE_THRESHOLD，判定档 c=$PROBE_VERIFY_C"
    # 峰值后行为观察（红线豁免档）：压垮点下一档（无则 2×压垮点），记录超载行为
    local overload_c=0 found=0 i
    for i in "${!PROBE_LEVELS[@]}"; do
        if [ "$found" = "1" ]; then overload_c=${PROBE_LEVELS[$i]}; break; fi
        [ "${PROBE_LEVELS[$i]}" = "$collapse_level" ] && found=1
    done
    [ "$overload_c" -gt 0 ] || overload_c=$((collapse_level * 2))
    # 上限 700：实测 c=1000（3000+ 并发连接）会把 WSL2 VM 的 CPU 完全打满，
    # 曾导致 vscode-server 心跳超时断连、docker-desktop 后端停止。700 已越过
    # 压垮点（500）足以观察过载行为，且不再击穿宿主。
    [ "$overload_c" -le 700 ] || overload_c=700
    say "--- $label-overload：峰值后行为观察（每客户端 -c $overload_c，$PROBE_Z，红线豁免）"
    metrics_sampler "$label-overload" "$(dur_secs "$PROBE_Z")" &
    if [ "$mode" = list ]; then
        parallel_hey -z "$PROBE_Z" -c "$overload_c" "$url"
    else
        parallel_multi "$mode" "$overload_c" "$PROBE_Z"
    fi
    collect
    summarize_overload "$label-overload" nginx "$((overload_c * NCLIENTS))" "$cache_tag"
    metrics_report "$label-overload" "$label-overload"
}

# verify_capacity <mode> <label> <threshold>：按探测档并发跑 VERIFY_Z 正式判定
verify_capacity() {
    local mode=$1 label=$2 threshold=$3 cache_tag=${4:-$1} aligned=${5:-0}
    local round nrounds=1 r1_rps=0 r2_rps=0 r1_p99=0 r2_p99=0 chosen=1
    declare -a R1_5XX=() R1_OTHER=() R1_TRANS=() R1_TOTAL=() R2_5XX=() R2_OTHER=() R2_TRANS=() R2_TOTAL=()
    # 两轮取优：WSL2 共享宿主跨运行噪声实测可达 ±40%（同档位同阈值 2890/4031），
    # 单轮断言会噪声闪失；"容量能否达到 X"由较优轮回答（噪声双向，两轮都差才 FAIL）
    [ "$aligned" = "1" ] || nrounds=2
    say "== $label 容量判定（每客户端 -c $PROBE_VERIFY_C，$VERIFY_Z ×$nrounds 轮）=="
    for round in $(seq 1 "$nrounds"); do
        if [ "$nrounds" -eq 2 ]; then
            say "--- $label 判定第 $round/2 轮"
        fi
        metrics_sampler "$label-verify-r$round" "$(dur_secs "$VERIFY_Z")" &
        if [ "$mode" = list ]; then
            parallel_hey -z "$VERIFY_Z" -c "$PROBE_VERIFY_C" "$URL"
        else
            parallel_multi "$mode" "$PROBE_VERIFY_C" "$VERIFY_Z"
        fi
        collect
        summarize "$label-r$round" "$label" "$((PROBE_VERIFY_C * NCLIENTS))" "$cache_tag"
        metrics_report "$label-verify-r$round" "$label-verify-r$round"
        if [ "$round" = "1" ]; then
            r1_rps=$TOT_RPS; r1_p99=$TOT_P99
            R1_5XX=("${CL_5XX[@]}"); R1_OTHER=("${CL_OTHER[@]}"); R1_TRANS=("${CL_TRANS[@]}"); R1_TOTAL=("${CL_TOTAL[@]}")
        else
            r2_rps=$TOT_RPS; r2_p99=$TOT_P99
            R2_5XX=("${CL_5XX[@]}"); R2_OTHER=("${CL_OTHER[@]}"); R2_TRANS=("${CL_TRANS[@]}"); R2_TOTAL=("${CL_TOTAL[@]}")
        fi
        sleep 2
    done
    if [ "$aligned" = "1" ]; then
        # 对照对齐档：档位继承自配对 case（b4↔b5），共享档可能超出本方容量区，
        # RPS/错误率/P99 仅记录不断言——对比结论由两份记录并排给出；5xx 红线仍在 summarize 强制执行
        say "$label 记录（对照对齐档 c=$PROBE_VERIFY_C）：RPS=$TOT_RPS，P99=${TOT_P99}s，错误率=$TOT_ERR（仅记录不断言）"
        sleep 2
        return 0
    fi
    # 取 RPS 较高轮恢复 CL_*/TOT_* 后断言
    if awk -v a="$r1_rps" -v b="$r2_rps" 'BEGIN { exit !(b > a) }'; then chosen=2; fi
    if [ "$chosen" = "1" ]; then
        TOT_RPS=$r1_rps; TOT_P99=$r1_p99
        CL_5XX=("${R1_5XX[@]}"); CL_OTHER=("${R1_OTHER[@]}"); CL_TRANS=("${R1_TRANS[@]}"); CL_TOTAL=("${R1_TOTAL[@]}")
    else
        TOT_RPS=$r2_rps; TOT_P99=$r2_p99
        CL_5XX=("${R2_5XX[@]}"); CL_OTHER=("${R2_OTHER[@]}"); CL_TRANS=("${R2_TRANS[@]}"); CL_TOTAL=("${R2_TOTAL[@]}")
    fi
    awk -v r="$TOT_RPS" -v t="$threshold" -v k="$VERIFY_RATIO" 'BEGIN { exit !(r >= k * t) }' \
        || fail "$label RPS=$TOT_RPS（第 $chosen 轮取优）应 ≥ ${VERIFY_RATIO}×阈值($threshold)=$(awk -v t="$threshold" -v k="$VERIFY_RATIO" 'BEGIN{printf "%.0f", t*k}')"
    for i in $(seq 1 "$NCLIENTS"); do
        j=$((i - 1))
        awk -v e="$(client_error_rate "$j")" 'BEGIN { exit !(e <= 0.005) }' \
            || fail "$label client-$i 错误率 > 0.5%（第 $chosen 轮）"
    done
    awk -v p="$TOT_P99" -v m="$VERIFY_P99" 'BEGIN { exit !(p <= m) }' \
        || fail "$label P99(max)=${TOT_P99}s 应 ≤ ${VERIFY_P99}s（判定宽松线，第 $chosen 轮）"
    say "$label 通过（两轮取优，第 $chosen 轮）：RPS=$TOT_RPS ≥ 0.95×阈值($threshold)，错误率≤0.5%，P99≤${VERIFY_P99}s"
    sleep 2
}

# entry_compare <label> <nginx_rps> <nginx_p99> <level>：直连 gateway 对照一轮（与 nginx
# 数字同并发档比较），断言 nginx 一跳代价。直连数字写入全局 ENTRY_DIRECT_RPS /
# ENTRY_DIRECT_P99（不可用 $() 捕获——say 输出会污染捕获流）
ENTRY_DIRECT_RPS=0; ENTRY_DIRECT_P99=0
entry_compare() {
    local label=$1 nginx_rps=$2 nginx_p99=$3 level=$4
    say "== $label 入口对照：直连 gateway（每客户端 -c $level，$PROBE_Z）=="
    metrics_sampler "$label-direct" "$(dur_secs "$PROBE_Z")" &
    parallel_hey -z "$PROBE_Z" -c "$level" "$GATEWAY_URL"
    collect
    summarize "$label-direct" gateway "$((level * NCLIENTS))" list
    metrics_report "$label-direct" "$label-direct"
    ENTRY_DIRECT_RPS=$TOT_RPS; ENTRY_DIRECT_P99=$TOT_P99
    # 0.80 为实测标定值：B 相位限流代码仍在执行（巨大阈值不拒绝但每请求走 Redis EVAL），
    # 经 nginx 相对直连的吞吐代价实测 ≈19%（2026-08-28 b1 探测 c=300 档），留 1% 裕量取 0.80
    awk -v n="$nginx_rps" -v d="$ENTRY_DIRECT_RPS" 'BEGIN { exit !(n >= 0.80 * d) }' \
        || fail "$label 经 nginx RPS=$nginx_rps 应 ≥ 0.80×直连($ENTRY_DIRECT_RPS)（nginx 一跳代价 >20%，实测 ≈$(awk -v n="$nginx_rps" -v d="$ENTRY_DIRECT_RPS" 'BEGIN{printf "%.0f", (1-n/d)*100}')%）"
    awk -v n="$nginx_p99" -v d="$ENTRY_DIRECT_P99" 'BEGIN { exit !(n <= 3 * d) }' \
        || fail "$label 经 nginx P99=${nginx_p99}s 应 ≤ 3×直连(${ENTRY_DIRECT_P99}s)"
    say "$label 入口对照通过：经 nginx RPS=$nginx_rps ≥ 0.80×直连($ENTRY_DIRECT_RPS)；P99 ${nginx_p99}s ≤ 3×直连(${ENTRY_DIRECT_P99}s)"
}

# ---------- B 相位 case ----------

run_b1() {
    b_phase_up
    say "== B1 标定：列表接口（无缓存，经 nginx）压垮点探测 =="
    probe_capacity list "B1"
    # 直连对照一档（量化 nginx 一跳代价），用崩溃前一档（同并发）的 nginx 数字比较，
    # 数字经全局 ENTRY_DIRECT_* 传回
    entry_compare "B1" "$PROBE_PREV_RPS" "$PROBE_PREV_P99" "$PROBE_PREV_C"
    update_threshold list "$PROBE_THRESHOLD" "$PROBE_COLLAPSE_LEVEL" "$PROBE_VERIFY_C" "$ENTRY_DIRECT_RPS" "$ENTRY_DIRECT_P99"
    say "B1 通过：list 阈值=$PROBE_THRESHOLD（压垮点 $PROBE_COLLAPSE_LEVEL），已写 $THRESHOLD_FILE"
}

run_b2() {
    b_phase_up
    local t col
    t=$(read_threshold list)
    if [ -z "$t" ]; then
        say "B2 依赖 list 阈值，先自动运行 B1 标定"
        run_b1
        t=$(read_threshold list)
    fi
    col=$(read_verify_c list)
    [ -n "$col" ] && [ "$col" -gt 0 ] || fail "阈值文件缺 list.verify_c，请先跑 b1"
    PROBE_VERIFY_C=$col
    say "== B2 列表容量判定（阈值 $t，判定档每客户端 -c $col）=="
    verify_capacity list "B2" "$t"
    entry_compare "B2" "$TOT_RPS" "$TOT_P99" "$PROBE_VERIFY_C"
    say "B2 通过：RPS=$TOT_RPS ≥ 0.95×阈值($t)"
}

run_b4() {
    b_phase_up
    [ -s "$SEED_STATE" ] || { say "B4 依赖播种，先自动运行 B3"; run_b3; }
    local n
    n=$(wc -l < "$SEED_STATE")
    [ "$n" -ge $((HOT_N + 2)) ] || { say "seed-state 热 ID 不足，重跑 B3"; run_b3; }
    say "== B4 有缓存容量：$HOT_N 个热 ID 持续打（Redis 命中）=="
    probe_capacity hot "B4"
    # 对照对 b4/b5 必须同判定档：继承对方已写入的档位（谁先跑谁定档），
    # 保证对比唯一变量是缓存开关；无对方记录时用本方曲线选择
    local paired_c
    paired_c=$(read_verify_c cold)
    if [ -n "$paired_c" ] && [ "$paired_c" -gt 0 ]; then
        PROBE_VERIFY_C=$paired_c; PAIR_ALIGNED=1
        say "  判定档对齐 B5：cold.verify_c=$paired_c（对照对同档位）"
    else
        PAIR_ALIGNED=0
    fi
    update_threshold hot "$PROBE_THRESHOLD" "$PROBE_COLLAPSE_LEVEL" "$PROBE_VERIFY_C" "" ""
    verify_capacity hot "B4" "$PROBE_THRESHOLD" hot "$PAIR_ALIGNED"
    say "--- 抽查热 ID 命中率（应全 HIT）"
    # 每 ID 两次 GET（第一次落缓存、第二次查头部）+ 并行 16：
    # 串行抽查 100 个 docker exec curl 耗时 >10s TTL，尾部 key 会过期误判 MISS（实测踩过）
    local result hits id
    result=$(sed -n "3,$((HOT_N + 2))p" "$SEED_STATE" | docker exec -i client-1 sh -c '
        xargs -P 16 -I{} sh -c "curl -s -o /dev/null http://nginx/api/order/orders/{}; \
            curl -s -o /dev/null -D - http://nginx/api/order/orders/{} | grep -io \"x-cache: [a-z]*\" | tr -d \"\\r\" | awk -v id={} \"{print id, \\\$2}\"" 2>/dev/null')
    hits=$(echo "$result" | grep -c "HIT" || true)
    if [ "$hits" -lt "$HOT_N" ]; then
        say "  首轮 $hits/$HOT_N HIT，剩余逐个重试（warm+check，排除过载风暴后的瞬时连接错误）"
        while read -r id; do
            if grep -q "^$id HIT" <<< "$result"; then continue; fi
            docker exec client-1 curl -s -o /dev/null "http://nginx/api/order/orders/$id"
            h=$(docker exec client-1 curl -s -o /dev/null -D - "http://nginx/api/order/orders/$id" | grep -io "x-cache: hit" || true)
            [ -n "$h" ] || fail "B4 热 ID $id 重试后仍未 HIT（缓存异常）"
            hits=$((hits + 1))
        done < <(sed -n "3,$((HOT_N + 2))p" "$SEED_STATE")
    fi
    say "B4 抽查通过：$hits/$HOT_N 热 ID 全部 HIT"
    say "B4 通过：阈值=$PROBE_THRESHOLD 已写 $THRESHOLD_FILE"
}

run_b5() {
    b_phase_up
    [ -s "$SEED_STATE" ] || { say "B5 依赖播种，先自动运行 B3"; run_b3; }
    cache_disable
    say "== B5 无缓存容量：与 B4 同热 ID 集直通落库（缓存已关闭）=="
    probe_capacity hot "B5" nocache
    # 对照对 b4/b5 必须同判定档：继承对方已写入的档位（谁先跑谁定档）
    local paired_c
    paired_c=$(read_verify_c hot)
    if [ -n "$paired_c" ] && [ "$paired_c" -gt 0 ]; then
        PROBE_VERIFY_C=$paired_c; PAIR_ALIGNED=1
        say "  判定档对齐 B4：hot.verify_c=$paired_c（对照对同档位）"
    else
        PAIR_ALIGNED=0
    fi
    update_threshold cold "$PROBE_THRESHOLD" "$PROBE_COLLAPSE_LEVEL" "$PROBE_VERIFY_C" "" ""
    verify_capacity hot "B5" "$PROBE_THRESHOLD" nocache "$PAIR_ALIGNED"
    say "--- 抽查与 B4 同 ID 集（缓存关闭下应全 MISS，并行 16）"
    local hits
    hits=$(sed -n "3,$((HOT_N + 2))p" "$SEED_STATE" | docker exec -i client-1 sh -c '
        xargs -P 16 -I{} sh -c "curl -s -o /dev/null http://nginx/api/order/orders/{}; \
            curl -s -o /dev/null -D - http://nginx/api/order/orders/{} | grep -i x-cache" 2>/dev/null' \
        | grep -c "HIT" || true)
    [ "$hits" -eq 0 ] || fail "B5 同 ID 集抽查 $hits 个 HIT（缓存未真正关闭）"
    say "B5 通过：同 ID 集抽查全 MISS，阈值=$PROBE_THRESHOLD 已写 $THRESHOLD_FILE"
    cache_restore
}

# ---------- B6 排队定位（直连 order-service 对照） ----------

run_b6() {
    # B6_LEG=1|2 只跑单腿（如 B6_LEG=2 bash scripts/load-test.sh b6 只跑带头直连 gateway），
    # 默认 all 两腿全跑
    say "== B6 排队定位：直连对照（同 B1 档位梯度，B6_LEG=${B6_LEG:-all}）=="
    local b6_os_col=0 b6h_col=0
    if [ "${B6_LEG:-all}" != "2" ]; then
        # 腿1：直连 order-service（连 gateway 都绕过）——无任何限流与代理
        say "--- B6 腿1：直连 order-service（无 gateway 无 EVAL）"
        HEY_HDR=""
        probe_capacity list "B6" list "http://order-service:8081/orders?page=1&size=1"
        b6_os_col=$PROBE_COLLAPSE_LEVEL
    fi
    if [ "${B6_LEG:-all}" != "1" ]; then
        # 腿2：直连 gateway + X-Edge-RateLimited 头（模拟 nginx 边缘层注入）——SCG 跳过限流
        # EVAL，只剩纯代理成本；与 b1 报告的 B1-direct（直连 gateway 不带头 = 代理+EVAL）
        # 对照即可拆分"gateway 纯代理"与"EVAL"两笔账
        say "--- B6 腿2：直连 gateway + X-Edge-RateLimited 头（SCG 跳过 EVAL，纯代理）"
        HEY_HDR="X-Edge-RateLimited: 1"
        probe_capacity list "B6h" list "$GATEWAY_URL"
        b6h_col=$PROBE_COLLAPSE_LEVEL
        HEY_HDR=""
    fi
    # 对照判读：与 B1（经 nginx）压垮点比较定位排队层
    local b1_col
    b1_col=$(read_collapse list)
    if [ -n "$b1_col" ] && [ "$b1_col" -gt 0 ]; then
        if [ "$b6_os_col" -gt 0 ]; then
            if [ "$b6_os_col" -gt "$b1_col" ]; then
                say "B6 结论（腿1 直连 order-service）：压垮点 c=$b6_os_col 高于经 nginx 的 c=$b1_col —— 排队在上游（nginx/gateway）"
            else
                say "B6 结论（腿1 直连 order-service）：压垮点 c=$b6_os_col ≤ 经 nginx 的 c=$b1_col —— 排队在 order-service/MySQL"
            fi
        fi
        if [ "$b6h_col" -gt 0 ]; then
            if [ "$b6h_col" -gt "$b1_col" ]; then
                say "B6 结论（腿2 gateway 带头无 EVAL）：压垮点 c=$b6h_col 高于经 nginx 的 c=$b1_col —— gateway 纯代理不是排队层"
            else
                say "B6 结论（腿2 gateway 带头无 EVAL）：压垮点 c=$b6h_col ≤ 经 nginx 的 c=$b1_col —— 排队在 gateway 纯代理层"
            fi
        fi
    else
        say "B6 提示：阈值文件缺 list.collapse_level（先跑 b1），对照结论请人工比对曲线"
    fi
    say "B6 完成：腿1=直连order-service，腿2=直连gateway带头（跳过EVAL）；b1 报告的 B1-direct 为直连gateway不带头（含EVAL）——三点对照拆分代理与 EVAL 成本"
}

# ---------- 执行（按 CASE 分发） ----------

say "== load-test 开始：case=$CASE =="
phase0
case "$CASE" in
    a1) run_a1 ;;
    a2) run_a2 ;;
    b1) run_b1 ;;
    b2) run_b2 ;;
    b3) run_b3 ;;
    b4) run_b4 ;;
    b5) run_b5 ;;
    b6) run_b6 ;;
    all)
        run_a1
        run_a2
        run_b1
        run_b2
        run_b3
        run_b4
        run_b5
        run_b6
        ;;
esac

# ---------- 报告收尾 ----------

{ printf '['; paste -sd, "$JSON_TMP"; printf ']\n'; } > "$JSON"
rm -f "$JSON_TMP"
# JSON 结构校验：曾因 "${9:-{}}" 的 bash 解析陷阱生成过整批损坏文件，收尾必须验
python3 -c "import json; json.load(open('$JSON'))" 2>/dev/null \
    && say "JSON 报告校验通过" \
    || say "警告：JSON 报告校验失败——结构损坏，请检查 write_json_line 调用"
say "== 全部场景通过（case=$CASE）=="
say "报告：$REPORT（结果）/ $LOG（日志）/ $JSON（结构化）"
[ -f "$THRESHOLD_FILE" ] && say "容量阈值：$THRESHOLD_FILE"
