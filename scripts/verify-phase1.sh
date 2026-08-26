#!/usr/bin/env bash
# 阶段 1 验收：在 compose 全栈启动后执行
set -euo pipefail
BASE=http://localhost:8080
GATEWAY=http://localhost:8080
# 宿主机若配置了 http_proxy，访问 localhost 也会被代理拦截，故每个 curl 统一加 --noproxy '*'

echo "== 1. 容器状态 =="
docker compose ps

echo "== 2. Nacos 服务注册 =="
TOKEN=$(curl -s --noproxy '*' -X POST 'http://localhost:8848/nacos/v3/auth/user/login' -d 'username=nacos&password=nacos' | sed 's/.*"accessToken":"\([^"]*\)".*/\1/')
curl -s --noproxy '*' -H "accessToken: $TOKEN" 'http://localhost:8848/nacos/v1/ns/service/list?pageNo=1&pageSize=10' || true
echo ""

echo "== 3. 经网关创建订单 =="
CREATE=$(curl -s --noproxy '*' -X POST $BASE/api/order/orders -H 'Content-Type: application/json' \
  -d '{"userId":1,"productName":"验收商品","amount":88.00}')
echo "$CREATE"
ID=$(echo "$CREATE" | sed 's/.*"id":\([0-9]*\).*/\1/')
[ -n "$ID" ] && [ "$ID" != "$CREATE" ] || { echo "FAIL: 未解析到订单 ID"; exit 1; }

echo "== 4. 缓存命中（第一次 MISS，第二次 HIT）=="
curl -si --noproxy '*' $BASE/api/order/orders/$ID | grep -i 'x-cache\|HTTP/' || true
curl -si --noproxy '*' $BASE/api/order/orders/$ID | grep -i 'x-cache\|HTTP/' || true

echo "== 5. 网关全局兜底限流（快速连发，预期出现 429）=="
for i in $(seq 1 25); do curl -s --noproxy '*' -o /dev/null -w "%{http_code} " $BASE/api/order/orders; done; echo

echo "== 6. 网关与订单服务健康 =="
curl -s --noproxy '*' $GATEWAY/actuator/health; echo
curl -s --noproxy '*' http://localhost:8081/actuator/health; echo

echo "== 阶段 1 验收完成 =="
