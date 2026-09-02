# -*- coding: utf-8 -*-
"""Redis 边界（Task 12 兜底限流本地化后）：

- redis-cli ping 通：redis 容器内 redis 进程可连（order-service 缓存、nginx 镜像写仍依赖）
- 限流判定已全本地（nginx lua_shared_dict + gateway 内存桶）：
  经 gateway 打突发流量后，Redis 里不应有任何限流 key（request_rate_limiter* / rate_limit:*）
  ——防回归：若有人重新引入 Redis 限流器，此断言失败，逼出架构裁决
  （原则：只有用户/业务维度的限流（需跨实例共享计数）才查 Redis）。
"""
import os
import subprocess

from conftest import burst_requests

# redis 容器名（Jenkins 环境可覆盖；docker CLI 需有 docker.sock 权限）
REDIS_CONTAINER = os.environ.get("REDIS_CONTAINER", "redis")


def _docker_redis_cli(*args) -> subprocess.CompletedProcess:
    """在 redis 容器里执行 redis-cli 命令，返回 CompletedProcess。"""
    return subprocess.run(
        ["docker", "exec", REDIS_CONTAINER, "redis-cli", *args],
        capture_output=True, text=True, timeout=30,
    )


def test_redis_reachable_and_limiter_keys_absent(api):
    """Redis 可达；限流判定本地化后 Redis 中不应出现任何限流 key。"""
    # 先并发 25 个请求（40/40 下 25 < 40 打不空桶，但放行与 429 都经过 gateway
    # 的本地桶判定）——若限流器走 Redis，此刻必然留下 key
    burst_requests(api, 25)

    # redis-cli ping：验证容器内 redis 进程可连（业务缓存/nginx 镜像的依赖仍在）
    pong = _docker_redis_cli("ping")
    assert pong.returncode == 0, f"docker exec redis-cli ping 执行失败: {pong.stderr}"
    assert pong.stdout.strip() == "PONG", \
        f"redis-cli ping 应返回 PONG，实际返回: {pong.stdout.strip()!r}"

    # 限流 key 必须不存在：本地化后限流判定零 Redis 写入
    for pattern in ("request_rate_limiter*", "rate_limit:*"):
        keys = _docker_redis_cli("keys", pattern)
        assert keys.returncode == 0, f"docker exec redis-cli keys 执行失败: {keys.stderr}"
        key_list = keys.stdout.strip().splitlines()
        assert not key_list, \
            f"限流已本地化，Redis 中不应有 {pattern} 键，实际: {key_list}"
