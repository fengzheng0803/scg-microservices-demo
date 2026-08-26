# -*- coding: utf-8 -*-
"""网关全局兜底限流：RequestRateLimiter（replenishRate=40, burstCapacity=40，全局单桶）。

关注点：令牌桶满时直接连发不会出现 429（前 40 个请求放行），
必须先快速打空桶，随后请求才会被限流返回 429。
（nginx 边缘层按客户端 IP 限流为 10/s+20；本测试直连 gateway，验证的是全局兜底桶的突发语义）
"""
from conftest import burst_requests


def test_ratelimit_429_after_bucket_exhausted(api):
    """先并发 50 个请求打空令牌桶，再验证后续请求出现 429。"""
    # 阶段 1：并发 50 个请求打空令牌桶（burstCapacity=40，refill 40/s 追不上并发；
    # 50 > 40 突发，余量 10 ≥ 3）
    # 并发是为了让 50 个请求挤在极短时间内到达，避免 refill 把桶补回去
    codes1 = burst_requests(api, 50)
    n429 = sum(1 for c in codes1 if c == 429)
    assert n429 >= 3, \
        f"并发 50 个请求应至少出现 3 次 429（实际 {n429} 次）: {sorted(codes1)}"

    # 阶段 2：桶已打空，紧随其后的请求应立即被限流（refill 40/s，补满 15 需 0.375s，
    # 而阶段 2 的 15 个并发在毫秒级到达，refill 追不上）
    codes2 = burst_requests(api, 15)
    n429b = sum(1 for c in codes2 if c == 429)
    assert n429b >= 1, \
        f"打空桶后紧随的请求应出现 429（实际 {n429b} 次）: {sorted(codes2)}"
