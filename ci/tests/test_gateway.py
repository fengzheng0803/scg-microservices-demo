# -*- coding: utf-8 -*-
"""网关连通性：经网关(8080)创建订单 + 查询订单，验证路由链路正常。

关注点：gateway 的 /api/order/** 路由应经 StripPrefix=2 转发到 order-service 的 /orders；
创建返回 201，且能用返回的雪花 ID 查询到同一订单（200、字段一致）。
"""


def test_gateway_create_and_query_order(api, cleanup):
    """经网关创建订单 -> 201；用返回 ID 查询 -> 200 且字段与创建时一致。"""
    # 创建订单：验证路由 /api/order/** -> order-service 链路通
    order = cleanup(api.create_order(user_id=88001, product_name="网关路由测试", amount=66.60))
    assert order["id"] is not None, "创建订单应返回雪花 ID"

    # 用返回的 ID 经网关查询：应命中同一订单（200），字段与创建时一致
    resp = api.get_order(order["id"])
    assert resp.status_code == 200, "经网关查询已创建订单应返回 200"
    body = resp.json()
    assert body["id"] == order["id"], "查询返回的订单 id 应与创建时一致"
    assert body["userId"] == 88001, "查询返回的 userId 应与创建时一致"
    assert body["productName"] == "网关路由测试", "查询返回的商品名应与创建时一致"
    assert body["amount"] == 66.60, "查询返回的金额应与创建时一致"
