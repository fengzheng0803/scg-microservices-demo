#!/usr/bin/env bash
# 首次启动 / 清库（docker compose down -v）后重建 Nacos 状态：
#   1. 等 Nacos 就绪（控制台端口 18080 的 v3 readiness 探针，对应容器内 8080）
#   2. 初始化管理员密码（幂等：已存在返回 code 409 视为成功）
#   3. 登录拿 accessToken，发布 order-service.yaml / gateway.yaml（upsert，幂等）
#   4. 业务服务未 healthy 时拉起（首次启动时配置缺失会启动失败，需重建配置后再起）
# 幂等：重复执行安全，不会破坏现有配置。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# --project-directory 保证无论从哪个 cwd 运行，.env 与 compose 文件都取自项目根
COMPOSE=(docker compose --project-directory "$PROJ_DIR" -f "$PROJ_DIR/docker-compose.yml")

NACOS=http://localhost:8848
CONSOLE=http://localhost:18080   # 宿主机映射的 3.x 控制台端口（容器内 8080）
ADMIN_PASSWORD=nacos

# 精确判断容器是否 healthy：字符串精确等于 "healthy"，容忍空值/starting/unhealthy
# （不能用 grep 子串匹配：unhealthy 也含 healthy 子串；也不能用 grep -c 计数：
#   零匹配退出码 1 在 set -o pipefail 下会触发 set -e 杀死脚本）
is_healthy() {
  [ "$(docker inspect -f '{{.State.Health.Status}}' "$1" 2>/dev/null)" = "healthy" ]
}

echo "== 等待 Nacos 就绪 =="
READY=0
for i in $(seq 1 75); do   # 75 * 2s = 150s
  CODE=$(curl -s --noproxy '*' -o /dev/null -w '%{http_code}' "$CONSOLE/v3/console/health/readiness" || echo 000)
  if [ "$CODE" = "200" ]; then READY=1; echo "[OK] Nacos 就绪（第 ${i} 次探测）"; break; fi
  sleep 2
done
[ "$READY" = "1" ] || { echo "[FAIL] Nacos 150s 内未就绪（先执行 docker compose up -d）"; exit 1; }

echo "== 初始化管理员密码（幂等）=="
INIT=$(curl -s --noproxy '*' -X POST "$NACOS/nacos/v3/auth/user/admin" -d "password=$ADMIN_PASSWORD")
case "$INIT" in
  *'"code":0'*) echo "[OK] 管理员密码初始化完成（新建 nacos/$ADMIN_PASSWORD）" ;;
  *'"code":409'* | *'have admin user'*) echo "[OK] 管理员已存在，跳过（幂等）" ;;
  *) echo "[FAIL] 管理员密码初始化失败: $INIT"; exit 1 ;;
esac

echo "== 登录获取 accessToken =="
LOGIN=$(curl -s --noproxy '*' -X POST "$NACOS/nacos/v3/auth/user/login" -d 'username=nacos&password=nacos')
TOKEN=$(echo "$LOGIN" | sed 's/.*"accessToken":"\([^"]*\)".*/\1/')
[ -n "$TOKEN" ] && [ "$TOKEN" != "$LOGIN" ] || { echo "[FAIL] 登录失败: $LOGIN"; exit 1; }
echo "[OK] 登录成功"

echo "== 发布业务配置（upsert，幂等）=="
publish() {
  local data_id="$1" content="$2"
  local resp
  resp=$(curl -s --noproxy '*' -X POST "$NACOS/nacos/v3/admin/cs/config" \
    -H "accessToken: $TOKEN" \
    --data-urlencode "dataId=$data_id" \
    --data-urlencode 'groupName=DEFAULT_GROUP' \
    --data-urlencode "content=$content")
  case "$resp" in
    *'"code":0'*) echo "[OK] 发布 $data_id" ;;
    *) echo "[FAIL] 发布 $data_id: $resp"; exit 1 ;;
  esac
}
publish order-service.yaml $'order:\n  cache:\n    ttl: 10s\n    max-size: 100'
publish gateway.yaml $'logging:\n  level:\n    org.springframework.cloud.gateway: INFO'

echo "== 确保业务服务运行（未 healthy 时拉起，已 healthy 跳过）=="
for svc in order-service gateway; do
  if is_healthy "$svc"; then
    echo "[OK] $svc 已 healthy，跳过"
  else
    echo "[..] $svc 未 healthy（首启配置缺失可能已退出），执行 up -d 拉起..."
    "${COMPOSE[@]}" up -d "$svc"
  fi
done

echo "== 等待业务服务 healthy =="
HEALTHY=0
for i in $(seq 1 24); do   # 24 * 5s = 120s；纯 bash 精确匹配，避免 grep 零匹配在 pipefail 下触发 set -e
  if is_healthy order-service && is_healthy gateway; then
    HEALTHY=1
    echo "[OK] order-service/gateway 全部 healthy"
    break
  fi
  sleep 5
done
[ "$HEALTHY" = "1" ] || { echo "[FAIL] 业务服务未在 120s 内 healthy"; "${COMPOSE[@]}" ps; exit 1; }

echo "== init-nacos.sh 完成 =="
"${COMPOSE[@]}" ps --format '{{.Name}} {{.Status}}'
