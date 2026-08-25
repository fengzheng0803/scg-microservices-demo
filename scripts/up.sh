#!/usr/bin/env bash
# 一键拉起微服务栈：确保 Docker 引擎运行 → compose 拉起/更新全部容器
# → Nacos 幂等初始化（密码+两条配置+拉起业务服务）→ 阶段 1 验收
# 用法：bash scripts/up.sh（WSL 重启后直接跑这一条即可）
set -euo pipefail
cd "$(dirname "$0")/.."

# 1. 确保 Docker 引擎运行（WSL2 + Docker Desktop 场景：引擎没起来时尝试拉起 Desktop）
if ! docker info >/dev/null 2>&1; then
    echo "== Docker 引擎未运行，尝试启动 Docker Desktop =="
    powershell.exe -Command "Start-Process 'C:\Program Files\Docker\Docker\Docker Desktop.exe'" 2>/dev/null || true
    for _ in $(seq 1 36); do
        docker info >/dev/null 2>&1 && break
        sleep 5
    done
    docker info >/dev/null 2>&1 || { echo "FAIL: Docker 引擎 3 分钟未就绪"; exit 1; }
fi
echo "== Docker 引擎就绪 =="

# 2. 拉起/更新全部容器（数据卷持久化，重启后原样恢复）
docker compose up -d --build

# 3. Nacos 幂等初始化：管理员密码 + order-service.yaml/gateway.yaml + 拉起业务服务
bash scripts/init-nacos.sh

# 4. 阶段 1 验收（6 项检查）
bash scripts/verify-phase1.sh
