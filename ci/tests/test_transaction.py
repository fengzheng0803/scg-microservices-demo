# -*- coding: utf-8 -*-
"""数据一致性：DB(MySQL) 与 API/缓存的一致性（不新增业务功能）。

关注点：
① 创建订单后，mysql orders 表存在该行且关键字段与 API 返回一致
② 删除订单后，DB 行消失；缓存被驱逐（再查询 404、无 HIT）
③ 写路径后：详情查询 HIT（缓存）返回的字段与 DB 行一致
"""
import os
from decimal import Decimal

import pymysql
import pytest

# MySQL 连接参数（Jenkins 容器内通过环境变量覆盖）
MYSQL_HOST = os.environ.get("MYSQL_HOST", "localhost")
MYSQL_PORT = int(os.environ.get("MYSQL_PORT", "3306"))
MYSQL_USER = os.environ.get("MYSQL_USER", "root")
MYSQL_PASSWORD = os.environ.get("MYSQL_ROOT_PASSWORD", "root123456")
MYSQL_DB = os.environ.get("MYSQL_DB", "order_db")


@pytest.fixture
def db():
    """连 MySQL 查询订单表的连接（函数级，用完关闭）。"""
    conn = pymysql.connect(
        host=MYSQL_HOST, port=MYSQL_PORT, user=MYSQL_USER,
        password=MYSQL_PASSWORD, database=MYSQL_DB, charset="utf8mb4",
    )
    try:
        yield conn
    finally:
        conn.close()


def _select_order(conn, order_id: int):
    """按主键查 orders 表，返回 dict 或 None。"""
    with conn.cursor() as cur:
        cur.execute(
            "SELECT id, order_no, user_id, product_name, amount, status, create_time "
            "FROM orders WHERE id = %s",
            (order_id,),
        )
        row = cur.fetchone()
    if row is None:
        return None
    cols = ["id", "order_no", "user_id", "product_name", "amount", "status", "create_time"]
    return dict(zip(cols, row))


def test_create_persists_in_mysql(api, cleanup, db):
    """① 创建订单 -> DB 行存在且字段一致。"""
    order = cleanup(api.create_order(user_id=77001, product_name="事务一致性商品", amount=123.45))
    oid = order["id"]

    # DB 中必须能查到该行
    row = _select_order(db, oid)
    assert row is not None, "创建订单后 mysql orders 表应存在该行"

    # 关键字段逐一比对（createTime 由 DB 默认填充，POST 响应为 null，不参与比对）
    assert str(row["order_no"]) == order["orderNo"], "DB order_no 应与 API 返回一致"
    assert row["user_id"] == order["userId"], "DB user_id 应与 API 返回一致"
    assert row["product_name"] == order["productName"], "DB product_name 应与 API 返回一致"
    assert row["amount"] == Decimal(str(order["amount"])), \
        "DB amount 应与 API 返回一致（DB DECIMAL vs JSON 数值）"
    assert row["status"] == order["status"], "DB status 应与 API 返回一致"


def test_delete_removes_db_row_and_cache(api, cleanup, db):
    """② 删除订单 -> DB 行消失 + 缓存被驱逐（再查询 404）。"""
    order = cleanup(api.create_order(product_name="删除一致性商品", amount=55.55))
    oid = order["id"]

    # 前提：订单先进入缓存（两次查询 MISS -> HIT）
    assert api.get_order(oid).headers.get("X-Cache") == "MISS", "首次查询应为 MISS"
    assert api.get_order(oid).headers.get("X-Cache") == "HIT", \
        "第二次查询应 HIT（确认订单已进缓存，为验证删除驱逐缓存做前提）"

    # 删除（@CacheEvict 应同步清掉缓存条目）
    resp = api.delete_order(oid)
    assert resp.status_code == 204, "删除订单应返回 204"

    # DB 行必须消失
    assert _select_order(db, oid) is None, "删除后 mysql 中不应再有该订单行"

    # 再查询：若缓存未被驱逐，会直接命中已删订单返回 200；现在应 404 且无 HIT
    r3 = api.get_order(oid)
    assert r3.status_code == 404, "删除后查询应 404（缓存已驱逐且 DB 无行）"
    assert r3.headers.get("X-Cache") != "HIT", "删除后不应再命中缓存"


def test_cache_hit_matches_db(api, cleanup, db):
    """③ 写路径后：详情查询 HIT（缓存）的字段与 DB 行一致。"""
    order = cleanup(api.create_order(user_id=77002, product_name="缓存DB一致性商品", amount=99.99))
    oid = order["id"]

    # 第一次查询回源 DB 并填充缓存，第二次 HIT（确认读的是缓存）
    assert api.get_order(oid).headers.get("X-Cache") == "MISS", "首次查询应为 MISS"
    r2 = api.get_order(oid)
    assert r2.headers.get("X-Cache") == "HIT", "第二次查询应命中缓存（验证读的是缓存）"
    cached = r2.json()

    # 缓存响应字段与 DB 行一致（缓存数据 = DB 数据的快照）
    row = _select_order(db, oid)
    assert row is not None, "DB 中应有该订单行"
    assert cached["id"] == row["id"], "缓存 id 应与 DB 一致"
    assert cached["orderNo"] == str(row["order_no"]), "缓存 orderNo 应与 DB 一致"
    assert cached["userId"] == row["user_id"], "缓存 userId 应与 DB 一致"
    assert cached["productName"] == row["product_name"], "缓存 productName 应与 DB 一致"
    assert Decimal(str(cached["amount"])) == row["amount"], "缓存 amount 应与 DB 一致"
    assert cached["status"] == row["status"], "缓存 status 应与 DB 一致"
    # createTime：缓存实体来自 DB 查询，JSON 为 ISO 串（2026-08-25T10:05:55），
    # 与 DB DATETIME（2026-08-25 10:05:55）对齐到秒比较
    db_ts = row["create_time"].strftime("%Y-%m-%d %H:%M:%S")
    api_ts = cached["createTime"].replace("T", " ")[:19]
    assert api_ts == db_ts, f"缓存 createTime 应与 DB 一致（API {api_ts} vs DB {db_ts}）"
