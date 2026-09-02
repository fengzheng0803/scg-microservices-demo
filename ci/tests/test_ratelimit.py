# -*- coding: utf-8 -*-
"""网关全局兜底限流：本地内存令牌桶（rate=40, burst=40，全局单桶，Task 12 本地化）。

关注点：令牌桶满时直接连发不会出现 429（前 40 个请求放行），
必须先快速打空桶，随后请求才会被限流返回 429。
（nginx 边缘层按客户端 IP 限流为 10/s+20；本测试直连 gateway，验证的是全局兜底桶的突发语义）
"""
from conftest import burst_requests


def test_ratelimit_429_after_bucket_exhausted(api):
    """先并发 100 个请求打空令牌桶，再验证后续请求出现 429。"""
    # 阶段 1：并发 100 个请求打空令牌桶（burstCapacity=40，refill 40/s）。
    # 余量取 60（100 - 40 突发 - 最多 ~20 个 refill）：50 并发时余量只有 10，
    # 在负载重的 Jenkins 环境线程铺开超过 0.25s 即被 refill 抵消（构建 #9 实测 0×429 的教训）
    codes1 = burst_requests(api, 100)
    n429 = sum(1 for c in codes1 if c == 429)
    assert n429 >= 3, \
        f"并发 100 个请求应至少出现 3 次 429（实际 {n429} 次）: {sorted(codes1)}"

    # 阶段 2：桶已打空，紧随其后的请求应立即被限流。30 并发 > 间隙 refill
    # （40/s × 典型间隙 ≤0.5s ≈ ≤20 个），余量充足（构建 #9 中 15 并发同样有铺开风险）
    codes2 = burst_requests(api, 30)
    n429b = sum(1 for c in codes2 if c == 429)
    assert n429b >= 1, \
        f"打空桶后紧随的请求应出现 429（实际 {n429b} 次）: {sorted(codes2)}"
