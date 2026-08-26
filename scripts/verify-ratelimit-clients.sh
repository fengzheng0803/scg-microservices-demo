#!/usr/bin/env bash
# Task 7 验收：nginx 边缘层 + lua 按 IP 限流 + 客户端隔离性
# 前置：docker compose up -d nginx（自动带 gateway + redis）；
#       bash scripts/launch-clients.sh（client-1..3，容器网络内 http://nginx/ 直连）
# 硬性红线：任何场景 [5xx] == 0（nginx/SCG 只允许 429 拒绝，不允许 5xx）
set -euo pipefail
cd "$(dirname "$0")/.."

URL='http://nginx/api/order/orders?page=1&size=1'
NCLIENTS=3

fail() { echo "FAIL: $*"; exit 1; }

# 在客户端容器内跑 hey（连接类异常不中断脚本，交给后续断言判定）
run_hey() {
    local c=$1; shift
    docker exec "client-$c" hey "$@" "$URL" 2>&1 || true
}

# 统计 hey 输出里指定状态码的响应数（只统计 Status code distribution 段；
# 该段行格式为 "  [200]\t5 responses"，状态码前有缩进空格）
count_code() {
    local want=$1
    printf '%s\n' "$2" | awk -v want="$want" -F'[][\t ]+' '
        /Status code distribution:/ { in_section = 1; next }
        /Error distribution:/      { in_section = 0 }
        in_section && /^[[:space:]]*\[[0-9]+\]/ { if ($2 == want) s += $3 }
        END { print s + 0 }
    '
}

# 统计 5xx 总数
count_5xx() {
    printf '%s\n' "$1" | awk -F'[][\t ]+' '
        /Status code distribution:/ { in_section = 1; next }
        /Error distribution:/      { in_section = 0 }
        in_section && /^[[:space:]]*\[[0-9]+\]/ { if ($2 >= 500 && $2 < 600) s += $3 }
        END { print s + 0 }
    '
}

# 红线：任何 hey 结果不允许出现 5xx
assert_no_5xx() {
    local n5xx
    n5xx=$(count_5xx "$1")
    [ "$n5xx" -eq 0 ] || fail "$2：出现 $n5xx 次 5xx（硬性红线）"
}

# nginx 日志基线：只统计本次脚本运行产生的行（可重复运行，不把历史 429 计入）
LOG_BASELINE=$(docker logs nginx 2>&1 | wc -l)

echo "== 0. 前置：客户端就绪 + SNAT 守卫 =="
for i in $(seq 1 "$NCLIENTS"); do
    docker inspect "client-$i" >/dev/null 2>&1 \
        || fail "client-$i 不存在，请先运行 bash scripts/launch-clients.sh"
done
mapfile -t IPS < <(for i in $(seq 1 "$NCLIENTS"); do
    docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "client-$i"
done)
NUNIQ=$(printf '%s\n' "${IPS[@]}" | sort -u | grep -c .)
[ "$NUNIQ" -eq "$NCLIENTS" ] || fail "客户端 IP 去重后为 $NUNIQ（应为 3）——SNAT 坍缩或容器异常"
for i in $(seq 1 "$NCLIENTS"); do
    echo "  client-$i: ${IPS[$((i-1))]}"
done

# 冒烟：各客户端经 nginx 打列表接口 == 200
for i in $(seq 1 "$NCLIENTS"); do
    CODE=$(docker exec "client-$i" curl -s -o /dev/null -w '%{http_code}' "$URL")
    [ "$CODE" = "200" ] || fail "client-$i 冒烟请求返回 $CODE（应为 200）"
done
echo "冒烟通过：3 客户端经 nginx 均返回 200"

echo "== Phase 1/2/3：依次打爆 client-1/2/3 的 IP 桶 =="
for p in 1 2 3; do
    echo "--- Phase $p：打爆 client-$p（IP ${IPS[$((p-1))]}）"

    # 触发：30 并发打空令牌桶（capacity=20，refill 10/s 追不上并发），[429] ≥ 3
    out=$(run_hey "$p" -n 30 -c 30)
    assert_no_5xx "$out" "Phase $p 触发"
    n=$(count_code 429 "$out")
    [ "$n" -ge 3 ] || fail "Phase $p 触发：[429] 应 ≥ 3，实际 $n"
    echo "Phase $p 触发通过：[429] = $n"

    # 持续：桶已打空，紧随其后的请求应立即被限流（refill 10/s 瞬间补不满），[429] ≥ 1
    out=$(run_hey "$p" -n 6 -c 6)
    assert_no_5xx "$out" "Phase $p 持续"
    n=$(count_code 429 "$out")
    [ "$n" -ge 1 ] || fail "Phase $p 持续：[429] 应 ≥ 1，实际 $n"
    echo "Phase $p 持续通过：[429] = $n"

    # 隔离：其余两客户端 5 并发 → [429] == 0（各自 IP 桶未被打爆）
    # 先 sleep 1 让 SCG 全局兜底桶回血（40/s，1s 补满 40；触发/持续刚打空它）：
    # 若紧跟隔离，其余客户端的请求会在 gateway 兜底桶上吃 429 并透传回来，污染隔离断言
    sleep 1
    for j in 1 2 3; do
        [ "$j" -eq "$p" ] && continue
        out=$(run_hey "$j" -n 5 -c 5)
        assert_no_5xx "$out" "Phase $p 隔离 client-$j"
        n=$(count_code 429 "$out")
        [ "$n" -eq 0 ] || fail "Phase $p 隔离：client-$j [429] 应为 0，实际 $n（按 IP 隔离失败）"
    done
    echo "Phase $p 隔离通过：其余两客户端 [429] = 0"

    # 恢复：sleep 3 等 refill（10/s × 3s = 30 > 容量 20 → 桶回满），再打 → [429] == 0
    sleep 3
    out=$(run_hey "$p" -n 5 -c 5)
    assert_no_5xx "$out" "Phase $p 恢复"
    n=$(count_code 429 "$out")
    [ "$n" -eq 0 ] || fail "Phase $p 恢复：[429] 应为 0，实际 $n（桶未恢复）"
    echo "Phase $p 恢复通过：[429] = 0"
done

echo "== Phase 4：全局证据 =="
# Redis 桶 key：3 个客户端 IP 各有一个 ratelimit:ip:<ip>（TTL 60s，全程在世）
KEYS=$(docker exec redis redis-cli --scan --pattern 'ratelimit:ip:*')
echo "$KEYS"
NIP=$(printf '%s\n' "$KEYS" | grep -oE 'ratelimit:ip:[0-9.]+' \
    | sed 's/^ratelimit:ip://' | sort -u | grep -c .)
[ "$NIP" -ge "$NCLIENTS" ] || fail "Redis 中 ratelimit:ip:* 桶 key 源 IP 去重 $NIP（应 ≥ 3）"
echo "Phase 4a 通过：Redis 桶 key 源 IP 去重 = $NIP"

# nginx access log 中本次运行产生的 429 行，remote_addr 去重 == 3
LOG429=$(docker logs nginx 2>&1 | tail -n +"$((LOG_BASELINE + 1))" \
    | awk '$1 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ && $0 ~ / 429 / {print $1}' | sort -u)
NLOG=$(printf '%s\n' "$LOG429" | grep -c .)
echo "$LOG429"
[ "$NLOG" -eq "$NCLIENTS" ] || fail "nginx 日志 429 行 remote_addr 去重 $NLOG（应为 3）"
echo "Phase 4b 通过：nginx 429 行 remote_addr 去重 = $NLOG"

echo "== 验收完成 =="
