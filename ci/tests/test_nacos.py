# -*- coding: utf-8 -*-
"""Nacos：① 服务注册可见；② 配置热刷新（order.cache.ttl 改 3s 验证 + 原值还原）。

关注点：
- 注册中心：gateway 与 order-service 都应出现在服务列表且实例健康
- 配置中心热刷新：把 order-service.yaml 的 order.cache.ttl 改为 3s 后，
  缓存应 3s 过期（同一订单：第二次查 HIT -> 等 4s -> 再查 MISS）
- 测试结束必须把配置还原成测试前的值（teardown 保证），不影响其他测试/业务

Nacos v3 API：
- 登录 POST /nacos/v3/auth/user/login（nacos/nacos）拿 accessToken
- 读/写配置 /nacos/v3/admin/cs/config（accessToken 放 header）
- 服务列表 v1 ns 接口（accessToken 放 query 参数）
"""
import os
import re
import time

import pytest
import requests

from conftest import NO_PROXY

# Jenkins 容器内通过环境变量覆盖（NACOS_URL=http://nacos:8848）
NACOS_URL = os.environ.get("NACOS_URL", "http://localhost:8848")
NACOS_USER = os.environ.get("NACOS_USER", "nacos")
NACOS_PASSWORD = os.environ.get("NACOS_PASSWORD", "nacos")

DATA_ID = "order-service.yaml"
GROUP = "DEFAULT_GROUP"
# 轮询验证热刷新的总超时（配置变更 -> 客户端长轮询拉取 -> @RefreshScope 重建缓存，通常 <3s）
REFRESH_DEADLINE = 90


def _nacos_login() -> str:
    """Nacos v3 登录，返回 accessToken。"""
    resp = requests.post(
        f"{NACOS_URL}/nacos/v3/auth/user/login",
        data={"username": NACOS_USER, "password": NACOS_PASSWORD},
        proxies=NO_PROXY, timeout=10,
    )
    assert resp.status_code == 200, f"Nacos 登录失败: HTTP {resp.status_code} {resp.text[:200]}"
    token = resp.json().get("accessToken")
    assert token, f"登录响应缺少 accessToken: {resp.text[:200]}"
    return token


def _get_config(token: str) -> dict:
    """读配置，返回 v3 admin API 的 data 对象（含完整 content）。"""
    resp = requests.get(
        f"{NACOS_URL}/nacos/v3/admin/cs/config",
        params={"dataId": DATA_ID, "groupName": GROUP},
        headers={"accessToken": token}, proxies=NO_PROXY, timeout=10,
    )
    body = resp.json()
    assert resp.status_code == 200 and body.get("code") == 0, \
        f"读配置失败: HTTP {resp.status_code} {resp.text[:300]}"
    return body["data"]


def _write_config(token: str, content: str):
    """写配置（覆盖 order-service.yaml 的完整内容）。"""
    resp = requests.post(
        f"{NACOS_URL}/nacos/v3/admin/cs/config",
        data={"dataId": DATA_ID, "groupName": GROUP, "content": content},
        headers={"accessToken": token}, proxies=NO_PROXY, timeout=10,
    )
    body = resp.json()
    assert resp.status_code == 200 and body.get("code") == 0 and body.get("data") is True, \
        f"写配置失败: HTTP {resp.status_code} {resp.text[:300]}"


@pytest.fixture(scope="module")
def nacos_token() -> str:
    """模块级登录一次，token 复用（ttl 18000s 足够整个测试）。"""
    return _nacos_login()


@pytest.fixture
def config_restore(nacos_token):
    """保存 order-service.yaml 原文，teardown 时原样写回（热刷新测试的还原保证）。"""
    original = _get_config(nacos_token)["content"]
    yield original
    _write_config(nacos_token, original)
    time.sleep(1)  # 给配置客户端一点时间拉取还原值，避免后续测试撞上刷新窗口


def test_nacos_services_registered(nacos_token):
    """① 服务注册：gateway 与 order-service 都应注册且实例健康。"""
    # 服务列表（v1 ns 接口，accessToken 走 query）：应包含两个服务
    resp = requests.get(
        f"{NACOS_URL}/nacos/v1/ns/service/list",
        params={"pageNo": 1, "pageSize": 100, "accessToken": nacos_token},
        proxies=NO_PROXY, timeout=10,
    )
    assert resp.status_code == 200, \
        f"服务列表接口失败: HTTP {resp.status_code} {resp.text[:200]}"
    doms = resp.json().get("doms", [])
    assert "gateway" in doms, f"服务列表中应有 gateway，实际: {doms}"
    assert "order-service" in doms, f"服务列表中应有 order-service，实际: {doms}"

    # 实例健康：order-service 至少有一个健康实例
    inst = requests.get(
        f"{NACOS_URL}/nacos/v1/ns/instance/list",
        params={"serviceName": "order-service", "accessToken": nacos_token},
        proxies=NO_PROXY, timeout=10,
    )
    assert inst.status_code == 200, \
        f"实例查询失败: HTTP {inst.status_code} {inst.text[:200]}"
    hosts = inst.json().get("hosts", [])
    assert hosts, "order-service 应至少有一个已注册实例"
    assert all(h.get("healthy") for h in hosts), \
        f"order-service 实例都应健康，实际: {[(h['ip'], h['port'], h.get('healthy')) for h in hosts]}"


def test_nacos_config_hot_refresh(api, cleanup, nacos_token, config_restore):
    """② 配置热刷新：ttl 改为 3s 后缓存 3s 过期；teardown 自动还原原值。

    验证算法（每个 attempt 用新订单）：
    r1=MISS r2=HIT -> 缓存已填充；随后轮询直到 MISS（缓存被重建清空，或 3s ttl 自然过期）
    -> r4 立刻 HIT（重建后重新填充）-> 等 4.5s -> r5 必须 MISS。
    轮询上限 8s < 原 ttl（10s），保证"轮询见 MISS"只可能是重建或新 3s 过期，
    不会把旧 ttl 的自然过期误判为生效；重建是单次的，观察后不再发生，r5 结果可信。
    """
    original = config_restore  # 测试前的完整配置内容（teardown 原样还原）
    m = re.search(r"ttl:\s*([0-9]+)s", original)
    assert m, f"配置中应有 ttl 秒值，实际内容: {original}"
    original_ttl = int(m.group(1))
    assert original_ttl != 3, f"测试前提：原 ttl 不应是 3s（当前 {original_ttl}s）"

    # 改配置：保持 YAML 结构，只把 ttl 换成 3s
    new_content = re.sub(r"ttl:\s*[0-9]+s", "ttl: 3s", original)
    assert "ttl: 3s" in new_content, "改写后的配置应包含 ttl: 3s"
    _write_config(nacos_token, new_content)

    # 轮询等待并验证 3s ttl 生效
    deadline = time.time() + REFRESH_DEADLINE
    observed = False
    while time.time() < deadline:
        order = cleanup(api.create_order(product_name="热刷新验证", amount=7.77))
        oid = order["id"]

        # r1：新订单从未被缓存，必须 MISS（若重建恰好发生，重试本轮）
        if api.get_order(oid).headers.get("X-Cache") != "MISS":
            time.sleep(1)
            continue
        # r2：紧接着应 HIT（缓存已填充）。若 MISS，说明重建恰好发生在两次查询之间，重试
        if api.get_order(oid).headers.get("X-Cache") != "HIT":
            time.sleep(1)
            continue

        # 轮询直到 MISS：缓存被重建清空（刷新生效），或 3s 新 ttl 自然过期
        # 8s 上限 < 原 ttl 10s，旧 ttl 的自然过期不会在此被误判为刷新生效
        poll_until = time.time() + 8
        while time.time() < poll_until:
            if api.get_order(oid).headers.get("X-Cache") == "MISS":
                break
            time.sleep(1)
        else:
            continue  # 8s 内未出现 MISS：重建未发生，换新订单重试

        # r4：重建/过期后立即查询应 HIT（重新填充缓存）
        if api.get_order(oid).headers.get("X-Cache") != "HIT":
            continue

        # 等 4.5s 后 r5：若 3s ttl 已生效则必然过期变 MISS；若仍是旧 ttl(10s) 则仍 HIT
        time.sleep(4.5)
        if api.get_order(oid).headers.get("X-Cache") == "MISS":
            observed = True
            break
        time.sleep(1)

    assert observed, "改 order.cache.ttl=3s 后应观察到 缓存HIT -> 4s后过期MISS（热刷新未生效）"
