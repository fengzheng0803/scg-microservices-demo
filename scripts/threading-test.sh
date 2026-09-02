#!/usr/bin/env bash
# 锁策略对比测试（threading-test）：两种 order.lock.enabled 值下，
# 3 客户端各同时发起 100 个 amount -1 修改请求（delta 读-改-写），对比耗时与最终 amount：
#   Phase 1 不加锁（enabled=false）：并发直行读-改-写 → 丢失更新，最终 amount ≠ 0，耗时应较短
#   Phase 2 加锁（enabled=true）：synchronized 全局监视器串行临界区 → 最终 amount == 0，耗时应较长
# 每相位前经 Nacos 热切换 order.lock.enabled（@RefreshScope 重建策略 bean，无需重启/重建），
# 结束 trap 恢复 enabled=true 并删除测试订单（幂等安全）。
# 直连 order-service:8081：绕过 nginx 边缘限流（默认 10rps，300 并发会被 429 干扰本测试）。
#
# 用法：bash scripts/threading-test.sh
# 前置：docker compose up -d（order-service healthy，Nacos 8848 可达）
set -euo pipefail
cd "$(dirname "$0")/.."

NACOS=http://localhost:8848
ORDER_URL=http://localhost:8081
NCLIENTS=3
REQS_PER_CLIENT=100
INIT_AMOUNT=300

TS=$(date +%Y%m%d-%H%M%S)
mkdir -p reports
BASE="reports/threading-test-$TS"
REPORT="$BASE.txt"
LOG="$BASE.log"
: > "$LOG"

fail() { echo "FAIL: $*" | tee -a "$LOG" >&2; exit 1; }
say()  { echo "$*" | tee -a "$LOG"; }

# build_report：从 LOG 抽取结果行生成 REPORT（仿 load-test 的收尾抽取）
build_report() {
    grep -E '^(== |FAIL|通过|警告|  测试订单|  完成|  恢复|  Phase)' "$LOG" > "$REPORT" 2>/dev/null || true
}

TMP=$(mktemp -d)
TEST_ORDER_ID=""
cleanup() {
    local rc=$?
    if [ -n "$TEST_ORDER_ID" ]; then
        say "== 清理测试订单 id=$TEST_ORDER_ID =="
        curl -s --noproxy '*' -m 10 -X DELETE "$ORDER_URL/orders/$TEST_ORDER_ID" -o /dev/null || true
    fi
    say "== 恢复 order.lock.enabled=true（trap EXIT）=="
    nacos_push_lock true || say "警告：lock 开关恢复失败，请手动在 Nacos 改 order-service.yaml"
    rm -rf "$TMP"
    build_report
    exit "$rc"
}
trap cleanup EXIT

# ---------- Nacos 推送（仿 init-nacos.sh 的 v3 路径：登录 + accessToken 头发布） ----------

# nacos_push_lock <true|false>：推 order-service.yaml（保留 cache/logging 段，仅改 lock.enabled）
nacos_push_lock() {
    local enabled=$1 login token content resp
    login=$(curl -s --noproxy '*' -m 5 -X POST "$NACOS/nacos/v3/auth/user/login" -d 'username=nacos&password=nacos')
    token=$(echo "$login" | sed 's/.*"accessToken":"\([^"]*\)".*/\1/')
    [ -n "$token" ] && [ "$token" != "$login" ] || { echo "Nacos 登录失败: $login" >&2; return 1; }
    content=$(printf 'order:\n  cache:\n    ttl: 10s\n    max-size: 100\n  lock:\n    enabled: %s\nlogging:\n  level:\n    com.example.order: INFO' "$enabled")
    resp=$(curl -s --noproxy '*' -m 10 -X POST "$NACOS/nacos/v3/admin/cs/config" \
        -H "accessToken: $token" \
        --data-urlencode "dataId=order-service.yaml" \
        --data-urlencode 'groupName=DEFAULT_GROUP' \
        --data-urlencode "content=$content")
    case "$resp" in
        *'"code":0'*) return 0 ;;
        *) echo "Nacos 发布失败: $resp" >&2; return 1 ;;
    esac
}

# ---------- 相位执行（unlocked|locked）----------
# 结果存全局 U_MS/U_FINAL/L_MS/L_FINAL（say 会污染 stdout，不用 $( ) 捕获）

U_MS=0; U_FINAL=""; L_MS=0; L_FINAL=""

run_phase() {
    local mode=$1 enabled=$2 id t0 t1 ok final
    say "== Phase：$mode（order.lock.enabled=$enabled）=="
    nacos_push_lock "$enabled" || fail "Nacos 推送 lock.enabled=$enabled 失败"
    sleep 8   # RefreshEvent 传播 + @RefreshScope 懒重建（与 load-test 缓存热切换同款等待）

    id=$(curl -s --noproxy '*' -m 10 -X POST "$ORDER_URL/orders" -H 'Content-Type: application/json' \
        -d '{"userId":900002,"productName":"thread-test","amount":300}' \
        | grep -o '"id":[0-9]*' | cut -d: -f2 | head -1)
    [ -n "$id" ] || fail "创建测试订单失败（初始 amount=$INIT_AMOUNT）"
    TEST_ORDER_ID=$id
    say "  测试订单 id=$id，初始 amount=$INIT_AMOUNT"

    t0=$(date +%s%3N)
    local c
    for c in $(seq 1 "$NCLIENTS"); do
        ( seq "$REQS_PER_CLIENT" | xargs -P "$REQS_PER_CLIENT" -I{} \
            curl -s --noproxy '*' -m 30 -o /dev/null -w '%{http_code}\n' -X PATCH "$ORDER_URL/orders/$id/amount?delta=-1" \
            > "$TMP/codes-$c.txt" ) &
    done
    wait
    t1=$(date +%s%3N)

    ok=$(cat "$TMP"/codes-*.txt 2>/dev/null | grep -c '^200$' || true)
    [ "$ok" -eq $((NCLIENTS * REQS_PER_CLIENT)) ] \
        || fail "$mode：200 响应 $ok/$((NCLIENTS * REQS_PER_CLIENT))（请求失败或超时）"
    final=$(curl -s --noproxy '*' -m 10 "$ORDER_URL/orders/$id" | grep -o '"amount":[0-9.]*' | cut -d: -f2)
    [ -n "$final" ] || fail "$mode：读取最终 amount 失败"
    say "  完成耗时 $((t1 - t0))ms，200 响应 $ok，最终 amount=$final"

    curl -s --noproxy '*' -m 10 -X DELETE "$ORDER_URL/orders/$id" -o /dev/null
    TEST_ORDER_ID=""

    if [ "$mode" = unlocked ]; then
        U_MS=$((t1 - t0)); U_FINAL=$final
    else
        L_MS=$((t1 - t0)); L_FINAL=$final
    fi
}

# ---------- 前置检查 ----------

say "== threading-test 开始 =="
[ "$(docker inspect -f '{{.State.Health.Status}}' order-service 2>/dev/null)" = "healthy" ] \
    || fail "order-service 未 healthy，请先 docker compose up -d"
CODE=$(curl -s --noproxy '*' -m 5 -o /dev/null -w '%{http_code}' "$ORDER_URL/orders?page=1&size=1")
[ "$CODE" = "200" ] || fail "order-service 冒烟请求返回 $CODE（应为 200）"
say "Phase 0 通过：order-service 就绪，冒烟 200"

# ---------- 两相位对比 ----------

run_phase unlocked false
run_phase locked   true

# ---------- 断言 ----------

awk -v a="$U_FINAL" 'BEGIN { exit !(a != 0) }' \
    || fail "不加锁最终 amount=$U_FINAL 应为非 0（未观察到丢失更新，竞态窗口太小或开关未生效）"
awk -v a="$L_FINAL" 'BEGIN { exit !(a == 0) }' \
    || fail "加锁最终 amount=$L_FINAL 应为 0（串行化失效）"
[ "$L_MS" -gt "$U_MS" ] \
    || say "警告：加锁耗时 ${L_MS}ms 未大于不加锁 ${U_MS}ms（环境噪声，可重跑确认）"
say "通过：不加锁 ${U_MS}ms → amount=$U_FINAL（丢失 $((INIT_AMOUNT - $(awk -v a="$U_FINAL" 'BEGIN{printf "%.0f", a}'))) 次扣减）；加锁 ${L_MS}ms → amount=0"
say "== threading-test 完成：$REPORT（结果）/ $LOG（日志）=="
