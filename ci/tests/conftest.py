# -*- coding: utf-8 -*-
"""系统测试公共 fixture 与 helper。

所有测试共享：
- ApiClient：经网关 8080 访问订单服务（创建/查询/删除），显式禁用代理
  （宿主机 http_proxy 指向本地代理，requests 默认会走代理访问 localhost 导致连接失败，必须禁用）
- cleanup fixture：自动记录并清理每个测试创建的订单，保证测试之间、多次运行之间数据独立
- burst_requests：并发打满网关限流令牌桶的辅助函数（test_ratelimit / test_redis 共用）

服务地址可通过环境变量覆盖（Jenkins 容器内：BASE_URL=http://gateway:8080）。
"""
import os
import threading
import time

import pytest
import requests

# 服务地址：Jenkins 容器内运行时通过环境变量覆盖（BASE_URL=http://gateway:8080）
BASE_URL = os.environ.get("BASE_URL", "http://localhost:8080")

# 禁用代理：宿主机 http_proxy/HTTPS_PROXY 会拦截对 localhost 的访问
NO_PROXY = {"http": None, "https": None}


class ApiClient:
    """经网关访问订单服务的客户端（代理已禁用）。"""

    def __init__(self, base_url: str = BASE_URL):
        self.base_url = base_url.rstrip("/")
        self.session = requests.Session()
        # 宿主机 http_proxy 指向本地代理（如 localhost:10077），requests 2.34 对
        # localhost 也不自动 bypass（should_bypass_proxies 只认 no_proxy 环境变量），
        # 仅设 proxies=None 字典仍会被环境变量代理抢走连接；必须 trust_env=False
        # 彻底关闭环境代理读取，再配合显式 proxies=None 双保险
        self.session.trust_env = False
        self.session.proxies = dict(NO_PROXY)
        self.session.headers["Content-Type"] = "application/json"

    def _request(self, method: str, url: str, **kwargs) -> requests.Response:
        """发请求；遇网关限流 429 时短等重试。

        令牌桶是全局单桶（gateway 本地内存桶，所有来源共享），test_redis / test_ratelimit 会打空桶，
        后面的测试可能瞬间撞上 429。429 表示请求根本没到 order-service（幂等安全），
        重试即可让断言只关注业务结果、不被限流状态干扰。
        """
        deadline = time.time() + 15
        while True:
            resp = self.session.request(method, url, timeout=10, **kwargs)
            if resp.status_code != 429 or time.time() > deadline:
                return resp
            time.sleep(0.6)  # 等令牌桶 refill（40/s → 0.6s 补 24 token）

    def create_order(self, user_id: int = 10001, product_name: str = "pytest测试商品",
                     amount: float = 88.88) -> dict:
        """POST /api/order/orders 创建订单（经网关），返回创建结果 JSON。"""
        resp = self._request(
            "POST", f"{self.base_url}/api/order/orders",
            json={"userId": user_id, "productName": product_name, "amount": amount},
        )
        assert resp.status_code == 201, \
            f"创建订单失败: HTTP {resp.status_code} {resp.text[:200]}"
        return resp.json()

    def get_order(self, order_id: int) -> requests.Response:
        """GET 订单详情，返回完整响应（X-Cache 头用于缓存命中断言）。"""
        return self._request("GET", f"{self.base_url}/api/order/orders/{order_id}")

    def delete_order(self, order_id: int) -> requests.Response:
        """DELETE 订单，返回完整响应（正常 204）。"""
        return self._request("DELETE", f"{self.base_url}/api/order/orders/{order_id}")


def burst_requests(api: ApiClient, n: int) -> list:
    """并发发 n 个 GET 列表请求，返回状态码列表。

    测限流/Redis 时用：并发打满令牌桶（burstCapacity=40，refill 40/s 追不上并发）。
    每个线程独立发请求（不用共享 Session，避免线程安全边界问题）。
    """
    codes: list = []
    lock = threading.Lock()

    def one():
        try:
            resp = requests.get(
                f"{api.base_url}/api/order/orders?page=1&size=1",
                proxies=NO_PROXY, timeout=10,
            )
            code = resp.status_code
        except requests.RequestException:
            code = -1  # 连接异常按失败计（不影响限流/Redis key 断言）
        with lock:
            codes.append(code)

    threads = [threading.Thread(target=one) for _ in range(n)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    return codes


@pytest.fixture(scope="session")
def api() -> ApiClient:
    """共用的订单 API 客户端（禁用代理）。"""
    return ApiClient()


@pytest.fixture
def cleanup(api: ApiClient):
    """跟踪本测试创建的订单 id，teardown 时逐个删除。

    每个测试创建订单后调用 cleanup(order_json) 登记；无论测试成功/失败，
    结束时都会清理，保证测试数据不残留。
    """
    tracked: list = []

    def track(order: dict) -> dict:
        tracked.append(order["id"])
        return order

    yield track

    for oid in reversed(tracked):
        try:
            resp = api.delete_order(oid)
            # 测试可能已自行删除（404），不算错误；其它异常也尽量不打断清理
            assert resp.status_code in (204, 404), \
                f"清理订单 {oid} 失败: HTTP {resp.status_code}"
        except (AssertionError, requests.RequestException):
            pass
