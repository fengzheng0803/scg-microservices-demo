# -*- coding: utf-8 -*-
"""网关限流：RequestRateLimiter（replenishRate=10, burstCapacity=20，按客户端 IP）。

关注点：令牌桶满时直接连发不会出现 429（前 20 个请求放行），
必须先快速打空桶，随后同一 IP 的请求才会被限流返回 429。
"""
from conftest import burst_requests


def test_ratelimit_429_after_bucket_exhausted(api):
    """先并发 30 个请求打空令牌桶，再验证后续请求出现 429。"""
    # 阶段 1：并发 30 个请求打空令牌桶（burstCapacity=20，refill 10/s 追不上并发）
    # 并发是为了让 30 个请求挤在极短时间内到达，避免 refill 把桶补回去
    codes1 = burst_requests(api, 30)
    n429 = sum(1 for c in codes1 if c == 429)
    assert n429 >= 3, \
        f"并发 30 个请求应至少出现 3 次 429（实际 {n429} 次）: {sorted(codes1)}"

    # 阶段 2：桶已打空，紧随其后的请求应立即被限流（refill 10/s，瞬间补不满）
    codes2 = burst_requests(api, 6)
    n429b = sum(1 for c in codes2 if c == 429)
    assert n429b >= 1, \
        f"打空桶后紧随的请求应出现 429（实际 {n429b} 次）: {sorted(codes2)}"
