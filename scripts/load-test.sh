#!/usr/bin/env bash
# Task 8 验收：全架构压测（限流态/容量态：吞吐 + 并发 + 入口对比）
# 前置：bash scripts/launch-clients.sh（client-1..3 常驻）+ docker compose up -d nginx；
#       本脚本不自动拉起（职责分离）。建议先以默认 env 重建一次：
#       docker compose up -d --build gateway nginx（使环境变量化后的默认值生效）
#
# A 相位（限流态，默认 nginx 10/20 + SCG 40/40）：
#   A1 吞吐：每客户端 hey -z 30s -q 10 -c 1（总投递 30/s，应全部放行）
#   A2 并发洪水：hey -z 20s -c 20 无 -q（验证按 IP 拦截：每客户端通过量 ≈ 10/s×20s+20 ≈ 220）
# B 相位（容量态，放大 env 重建 nginx+gateway 1000/2000 + 1000/2000）：
#   B1 容量吞吐（经 nginx）、B2 入口对比（直连 gateway）、B3 并发梯度（-c 10/50/100）
#   放大重建后 trap 保证脚本任何退出路径都以默认配置恢复重建
# 硬性红线：全程 [5xx] == 0（nginx/SCG 只允许 429 拒绝，不允许 5xx）。
# 错误口径：429 单独统计不计入错误；错误 = 5xx + 其他非 2xx 非 429 + 超时 + 连接失败。
# 目标 URL 必须是容器网络内服务名（禁止 localhost 起压——SNAT 坍缩单 IP）。
set -euo pipefail
cd "$(dirname "$0")/.."

URL='http://nginx/api/order/orders?page=1&size=1'
GATEWAY_URL='http://gateway:8080/api/order/orders?page=1&size=1'
NCLIENTS=3
TS=$(date +%Y%m%d-%H%M%S)
mkdir -p reports
TXT="reports/load-test-$TS.txt"
JSON="reports/load-test-$TS.json"
JSON_TMP="$JSON.tmp"
: > "$TXT"
: > "$JSON_TMP"

fail() { echo "FAIL: $*" | tee -a "$TXT" >&2; exit 1; }
say()  { echo "$*" | tee -a "$TXT"; }

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

# ---------- B 相位放大重建后的恢复（任何退出路径都回到默认配置） ----------

TMP=$(mktemp -d)
B_AMPLIFIED=0
cleanup() {
    local rc=$?
    rm -rf "$TMP"
    if [ "$B_AMPLIFIED" = "1" ]; then
        say "== 恢复默认限流配置（trap EXIT：默认 env 重建 gateway+nginx）=="
        if docker compose up -d --build gateway nginx 2>&1 | tee -a "$TXT"; then
            wait_healthy nginx gateway 2>/dev/null || say "警告：恢复后未 healthy，请检查 docker compose ps"
        else
            say "警告：默认配置恢复失败，请手动执行 docker compose up -d --build gateway nginx"
        fi
    fi
    exit "$rc"
}
trap cleanup EXIT

# ---------- hey 输出解析（沿用 verify-ratelimit-clients.sh 的 awk 口径） ----------

# parse_status <output>：Status code distribution 段 → "2xx 429 5xx 其他 响应总数"
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

# count_transport_errors <output>：Error distribution 段计数合计（超时/连接失败等传输层错误）
count_transport_errors() {
    printf '%s\n' "$1" | awk -F'[][\t ]+' '
        /Error distribution:/ { in_section = 1; next }
        in_section && /^[[:space:]]*\[[0-9]+\]/ { s += $2 }
        END { print s + 0 }
    '
}

extract_rps() { printf '%s\n' "$1" | awk '/Requests\/sec:/ { print $2; exit }'; }
extract_p99() { printf '%s\n' "$1" | awk '/Latency distribution:/ { in_dist=1; next } in_dist && /^[[:space:]]*99% in / { print $3; exit }'; }

# ---------- 起压与统计 ----------

# 在 client-N 内跑 hey：输出追加进 TXT（完整日志），并分存 TMP/client-N.out 供解析
run_client() {
    local c=$1; shift
    docker exec "client-$c" hey "$@" 2>&1 | tee -a "$TXT" > "$TMP/client-$c.out" || true
}

# 并发在 client-1..N 上跑相同 hey 参数（起压目标 URL 由调用方作为最后一个参数传入）
parallel_hey() {
    local c
    for c in $(seq 1 "$NCLIENTS"); do run_client "$c" "$@" & done
    wait
}

out() { cat "$TMP/client-$1.out"; }

# 收集 client-1..3 指标到 CL_* 数组（每次 parallel_hey 后调用）
declare -a CL_RPS=() CL_P99=() CL_2XX=() CL_N429=() CL_5XX=() CL_OTHER=() CL_TOTAL=() CL_TRANS=()
collect() {
    local i j o two n4 n5 oth tot
    for i in $(seq 1 "$NCLIENTS"); do
        j=$((i - 1))
        o=$(out "$i")
        CL_RPS[$j]=$(extract_rps "$o")
        CL_P99[$j]=$(extract_p99 "$o")
        [ -n "${CL_P99[$j]}" ] || fail "client-$i 未输出 99% 延迟行，无法计算 P99"
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

# write_json_line <scenario> <entry> <concurrency> <rps> <p99> <error_rate> <n429> <per_ip_429>
write_json_line() {
    printf '{"scenario":"%s","entry":"%s","concurrency":%s,"rps":%s,"p99":%s,"error_rate":%s,"n429":%s,"per_ip_429":%s}\n' \
        "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" >> "$JSON_TMP"
}

# summarize <scenario> <entry> <concurrency>：汇总打印 + 写 JSON 行 + 红线 [5xx]==0
# 汇总结果存入全局：TOT_RPS / TOT_P99 / TOT_429 / TOT_5XX / TOT_ERR
summarize() {
    local scenario=$1 entry=$2 concurrency=$3
    local i j ip429="" rps_sum=0 p99_max=0 nerr=0
    TOT_RPS=0; TOT_P99=0; TOT_429=0; TOT_5XX=0; TOT_ATTEMPTS=0
    for i in $(seq 1 "$NCLIENTS"); do
        j=$((i - 1))
        rps_sum=$(awk -v s="$rps_sum" -v r="${CL_RPS[$j]}" 'BEGIN { print s + r }')
        p99_max=$(awk -v m="$p99_max" -v p="${CL_P99[$j]}" 'BEGIN { if (p > m) print p; else print m }')
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
    say "  合计 RPS=$TOT_RPS  P99(max)=${TOT_P99}s  请求=$TOT_ATTEMPTS  429=$TOT_429  5xx=$TOT_5XX  错误率=$TOT_ERR"
    write_json_line "$scenario" "$entry" "$concurrency" "$TOT_RPS" "$TOT_P99" "$TOT_ERR" "$TOT_429" "{$ip429}"
    [ "$TOT_5XX" -eq 0 ] || fail "$scenario 出现 $TOT_5XX 次 5xx（硬性红线）"
}

# ---------- Phase 0 前置检查（不自动拉起，职责分离） ----------

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

# ---------- A 相位（限流态：默认配置 nginx 10/20 + SCG 40/20） ----------

say "== A 相位（限流态：默认配置 nginx 10/20 + SCG 40/40）=="

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

say "== A2 并发洪水：每客户端 hey -z 20s -c 20（验证按 IP 拦截）=="
parallel_hey -z 20s -c 20 "$URL"
collect
for i in $(seq 1 "$NCLIENTS"); do
    j=$((i - 1))
    n=${CL_N429[$j]}; t=${CL_TOTAL[$j]}
    awk -v n="$n" -v t="$t" 'BEGIN { exit !(t > 0 && n/t >= 0.8) }' \
        || fail "A2 client-$i [429]=$n 占响应 $t 的比例应 ≥ 80%（按 IP 拦截不足）"
done
summarize A2 nginx 60
say "A2 通过：3 客户端各有独立 429 且占比 ≥ 80%（压测下按 IP 分桶仍成立）"
sleep 2

# ---------- B 相位（容量态：放大 env 重建 nginx+gateway） ----------

say "== B 相位（容量态：放大 env 重建 nginx+gateway）=="
say "--- 放大重建：RATE_LIMIT_RPS=1000 RATE_LIMIT_CAP=2000 SCG_RATE_LIMIT_RPS=1000 SCG_RATE_LIMIT_BURST=2000"
RATE_LIMIT_RPS=1000 RATE_LIMIT_CAP=2000 SCG_RATE_LIMIT_RPS=1000 SCG_RATE_LIMIT_BURST=2000 \
    docker compose up -d --build gateway nginx 2>&1 | tee -a "$TXT" || fail "放大重建失败"
B_AMPLIFIED=1
wait_healthy nginx gateway
say "  容器内 env 证据：nginx RATE=$(docker exec nginx sh -c 'echo $RATE_LIMIT_RPS/$RATE_LIMIT_CAP')，gateway SCG=$(docker exec gateway sh -c 'echo $SCG_RATE_LIMIT_RPS/$SCG_RATE_LIMIT_BURST')"
CODE=$(docker exec client-1 curl -s -o /dev/null -w '%{http_code}' "$URL")
[ "$CODE" = "200" ] || fail "放大重建后冒烟请求返回 $CODE（应为 200）"
say "  放大后冒烟通过"
sleep 2

say "== B1 容量吞吐（经 nginx）：每客户端 hey -z 30s -c 20 -q 15（总投递 900/s）=="
parallel_hey -z 30s -c 20 -q 15 "$URL"
collect
summarize B1 nginx 60
B1_RPS=$TOT_RPS
awk -v r="$TOT_RPS" 'BEGIN { exit !(r >= 150) }' || fail "B1 合计 RPS=$TOT_RPS 应 ≥ 150（WSL2 折损后安全下限）"
for i in $(seq 1 "$NCLIENTS"); do
    j=$((i - 1))
    awk -v p="${CL_P99[$j]}" 'BEGIN { exit !(p <= 0.3) }' || fail "B1 client-$i P99=${CL_P99[$j]}s 应 ≤ 0.3s"
    awk -v e="$(client_error_rate "$j")" 'BEGIN { exit !(e <= 0.005) }' || fail "B1 client-$i 错误率>0.5%"
done
say "B1 通过：合计 RPS=$TOT_RPS ≥ 150，P99(max)≤0.3s，错误率≤0.5%"
sleep 2

say "== B2 入口对比（直连 gateway）：同参数打 http://gateway:8080/... =="
parallel_hey -z 30s -c 20 -q 15 "$GATEWAY_URL"
collect
summarize B2 gateway 60
awk -v a="$TOT_RPS" -v b="$B1_RPS" 'BEGIN { exit !(a >= 0.85 * b) }' \
    || fail "B2 RPS=$TOT_RPS 应 ≥ 0.85×B1($B1_RPS)=$(awk -v b="$B1_RPS" 'BEGIN{printf "%.1f", 0.85*b}')（lua+redis 开销 ≤15%）"
say "B2 通过：直连 RPS=$TOT_RPS ≥ 0.85×B1（$B1_RPS）"
sleep 2

say "== B3 并发梯度（经 nginx）：每客户端 -z 15s -c 10/50/100（总并发 30/150/300）=="
declare -A B3_RPS=()
for c in 10 50 100; do
    say "--- B3-c$c：并发 $((c * NCLIENTS))（每客户端 -c $c，15s）"
    parallel_hey -z 15s -c "$c" "$URL"
    collect
    summarize "B3-c$c" nginx "$((c * NCLIENTS))"
    B3_RPS[$c]=$TOT_RPS
    maxerr=0.005
    [ "$c" = "100" ] && maxerr=0.01
    for i in $(seq 1 "$NCLIENTS"); do
        j=$((i - 1))
        awk -v e="$(client_error_rate "$j")" -v m="$maxerr" 'BEGIN { exit !(e <= m) }' \
            || fail "B3-c$c client-$i 错误率 > $maxerr"
    done
    say "B3-c$c 通过：错误率 ≤ $maxerr"
    sleep 2
done
awk -v a="${B3_RPS[100]}" -v b="${B3_RPS[50]}" 'BEGIN { exit !(a >= 0.8 * b) }' \
    || fail "B3 RPS(c=100)=${B3_RPS[100]} 应 ≥ 0.8×RPS(c=50)=${B3_RPS[50]}（饱和而非崩溃）"
say "B3 通过：RPS(c=100)=${B3_RPS[100]} ≥ 0.8×RPS(c=50)=${B3_RPS[50]}"

# ---------- 报告收尾 ----------

{ printf '['; paste -sd, "$JSON_TMP"; printf ']\n'; } > "$JSON"
rm -f "$JSON_TMP"
say "== 全部场景通过 =="
say "报告：$TXT / $JSON"
