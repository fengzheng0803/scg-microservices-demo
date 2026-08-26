#!/usr/bin/env bash
# 拉起 N 个客户端容器（默认 3，参数可扩展，如 N=10），充当独立 IP 的"用户"
# 用法：bash scripts/launch-clients.sh [N]
#
# 关键约束（SNAT）：
#   客户端必须用裸 docker run 挂 microservices-net，经容器网络直连 http://nginx/
#   容器间流量保留真实源 IP；任何经宿主机发布端口的压测（localhost 起压）都会被
#   Docker 入站 SNAT 坍缩为单 IP，按 IP 限流演示失效。禁止 localhost 起压。
# 幂等：已存在的 client-1..N 先 docker rm -f 再重建。
set -euo pipefail
cd "$(dirname "$0")/.."

N=${1:-3}
NET=microservices_microservices-net
IMAGE=loadgen:latest

# 1. 幂等清理旧容器（参数缩小时也能清掉多余的）
for i in $(seq 1 "$N"); do
    docker rm -f "client-$i" >/dev/null 2>&1 || true
done

# 2. loadgen 镜像不存在时构建（存在则跳过）
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    echo "== 构建 $IMAGE =="
    docker build -t "$IMAGE" ./loadgen
fi

# 3. 循环拉起：sleep infinity 常驻，按需 docker exec client-N hey ... 打流
for i in $(seq 1 "$N"); do
    docker run -d --name "client-$i" --hostname "client-$i" \
        --network "$NET" "$IMAGE" sleep infinity >/dev/null
done

# 4. 打印 用户/IP 表格（与 nginx 日志 / Redis 桶 key 对账）
echo "== 客户端容器 =="
for i in $(seq 1 "$N"); do
    # range 形式遍历 .NetworkSettings.Networks（不能写含连字符的键名路径）
    IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "client-$i")
    echo "client-$i  $IP"
done
