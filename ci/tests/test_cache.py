# -*- coding: utf-8 -*-
"""Caffeine 本地缓存：同一订单连续查询，首次 MISS、第二次 HIT。

关注点：order-service 用 Caffeine 缓存订单详情（@Cacheable + CacheManager "orders"），
controller 依据 cache.get(id) 是否命中设置 X-Cache: MISS/HIT 响应头。
"""


def test_caffeine_miss_then_hit(api, cleanup):
    """同一订单查两次：第一次 X-Cache: MISS，第二次 X-Cache: HIT。"""
    order = cleanup(api.create_order(product_name="缓存命中测试", amount=12.34))
    oid = order["id"]

    # 第一次查询：缓存中无此订单，应 MISS（并回源 DB 填充缓存）
    resp1 = api.get_order(oid)
    assert resp1.status_code == 200, "订单查询应返回 200"
    assert resp1.headers.get("X-Cache") == "MISS", \
        "首次查询缓存未命中应返回 X-Cache: MISS"

    # 第二次查询：同一订单应命中缓存，X-Cache 应为 HIT
    resp2 = api.get_order(oid)
    assert resp2.status_code == 200, "订单查询应返回 200"
    assert resp2.headers.get("X-Cache") == "HIT", \
        "第二次查询应命中缓存返回 X-Cache: HIT"

    # 缓存命中的响应体应与首次回源结果一致（缓存是 DB 数据的快照）
    assert resp2.json() == resp1.json(), \
        "缓存命中的响应体应与首次回源查询结果一致"
