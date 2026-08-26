# -*- coding: utf-8 -*-
"""Redis 生效：网关限流器（RedisRateLimiter）把令牌桶存到 Redis。

关注点：
- redis-cli ping 通：redis 容器内 redis 进程可连
- 限流后 Redis 里有 request_rate_limiter.* 令牌桶 key（含 route id 与全局桶 key "global"）
先打空令牌桶产生限流 key，再断言 key 存在。
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


def test_redis_has_rate_limiter_keys(api):
    """打空限流桶后：Redis 中应有 request_rate_limiter* 令牌桶 key。"""
    # 先并发 25 个请求打空令牌桶：任何请求（放行或 429）都会经过限流器读写 Redis，
    # 保证 Redis 里必然留下令牌桶 key
    burst_requests(api, 25)

    # redis-cli ping：验证容器内 redis 进程可连（间接证明限流器写入的目标可访问）
    pong = _docker_redis_cli("ping")
    assert pong.returncode == 0, f"docker exec redis-cli ping 执行失败: {pong.stderr}"
    assert pong.stdout.strip() == "PONG", \
        f"redis-cli ping 应返回 PONG，实际返回: {pong.stdout.strip()!r}"

    # 限流 key 必须存在：请求经过 RedisRateLimiter 后应留下令牌桶键
    keys = _docker_redis_cli("keys", "request_rate_limiter*")
    assert keys.returncode == 0, f"docker exec redis-cli keys 执行失败: {keys.stderr}"
    key_list = keys.stdout.strip().splitlines()
    assert key_list, "限流请求后 Redis 中应有 request_rate_limiter* 键（令牌桶）"
    assert any(k.endswith(".tokens") for k in key_list), \
        f"应存在令牌桶 tokens 键，实际: {key_list}"
