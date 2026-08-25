# 微服务架构最小集合 · 设计方案 B（Kong 单注册体系）

- 日期：2026-08-24
- 状态：**仅设计储备**（当前实施首选为 [SCG 方案](2026-08-24-microservices-arch-scg-design.md)；第三方案见 [OpenResty 方案](2026-08-24-microservices-arch-openresty-design.md)）
- 定位：网关层功能（路由/LB/限流/JWT）由 Kong 承担，服务不注册、全流量过 Kong 的单注册模型

## 1. 目标与选型原则

**目标**：与方案 A 相同（注册、配置、网关、缓存、限流、熔断、认证、MQ），但追求"组件少、网关性能强、功能靠插件"的通用微服务形态，不绑定 Spring Cloud 网关体系。

**选型原则**：组件按自身优劣选择。选 Kong 的理由：OpenResty 内核性能强、rate-limiting/jwt 插件开箱即用、声明式配置（DB-less 模式零数据库依赖）。代价：网关层熔断无原生支持、JWT 校验在插件里（Java 侧不可见）、与"nginx+lua 自建限流"功能重复需二选一。

## 2. 版本基线

| 组件 | 版本 | 状态 |
|------|------|------|
| JDK / Boot / Cloud / SCA / Nacos / MyBatis-Plus / MySQL / Redis / RabbitMQ / jjwt | 同方案 A §2 | 同方案 A |
| Kong | kong:3（实施时锁定小版本） | 待锁定 |
| nginx | **本方案不使用**（Kong 即边缘网关，避免两层 Lua 网关冗余） | 确定 |

## 3. 全景架构（阶段 3 完整形态，共 9 容器）

```
client
  │ :8000 (proxy) / :8002 (Kong Manager)
  ▼
Kong (DB-less 声明式：路由+ring-balancer+rate-limiting 插件(Redis)+jwt 插件)
  ├──────────────┬──────────────┐
  ▼              ▼              ▼
order-service  user-service  auth-service
:8081          :8082          :8083
  │ Caffeine      │ MySQL(users)  │ 签发JWT(HS256)
  │ Resilience4j  │               │
  └─ 服务间调用走 Kong: http://kong:8000/api/user/...（单注册模型）
  ▼
mysql-order(:3306)   mysql-nacos(:3307)   redis(:6379)   rabbitmq(:5672)
  ▲                      ▲                    ▲              ▲
  └───── nacos(:8848, 仅配置中心, 服务不注册)──┘   Kong 限流插件后端    订单 MQ
```

| 容器 | 镜像 | 端口 | 职责 | 加入阶段 |
|------|------|------|------|---------|
| mysql-order | mysql:8.4 | 3306 | 业务库 | 1 |
| mysql-nacos | mysql:8.4 | 3307 | Nacos 配置库 | 1 |
| nacos | nacos/nacos-server:v3.0.3 | 8848/9848 | **仅配置中心**（注册职责由 Kong 接管） | 1 |
| redis | redis:7-alpine | 6379 | Kong 限流插件计数后端 | 1 |
| order-service | 自建 | 8081 | 订单服务（不注册） | 1 |
| kong | kong:3 | 8000/8001/8002 | 网关+注册(声明式 upstream)+LB+限流 | 1 |
| user-service | 自建 | 8082 | 用户服务（不注册） | 2 |
| auth-service | 自建 | 8083 | 签发 JWT | 3 |
| rabbitmq | rabbitmq:3-management | 5672/15672 | MQ | 3 |

**注册模型（本方案核心决策）**：Kong 声明式 upstream 单注册——服务不向任何注册中心自注册，Kong 的 `kong.yml` 声明所有服务/路由/upstream（compose 固定地址 targets）。服务间调用（order→user）**也走 Kong**（`http://kong:8000/api/user/...`），因此不存在第二套注册模型，无双注册同步问题。代价：服务间调用多一跳；固定地址静态配置，无动态扩缩容演示（compose 规模下本就不需要）。

## 4. 阶段划分

| 阶段 | 新增 | 累计容器 | 学习主题 |
|------|------|---------|---------|
| 1 最小集合 | 双 MySQL、Nacos(仅配置)、Redis、order-service、Kong | 6 | 声明式网关、Kong 路由/LB、插件限流、本地缓存 |
| 2 调用链与弹性 | user-service；order-service 加 Resilience4j | 7 | 服务间调用（过网关）、熔断降级、服务级限流 |
| 3 安全与异步 | auth-service、rabbitmq；Kong 加 jwt 插件 | 9 | 认证、插件式 JWT 校验、消息异步 |

**排除项**：同方案 A（Seata/RocketMQ/Sentinel/K8s）+ nginx（与 Kong 功能重复）。

## 5. 阶段 1 详细设计

### 5.1 基础设施

mysql-order、mysql-nacos、redis 与方案 A §5.1 完全相同。
> ⚠️ Nacos 3.x 实测形态与 2.x 差异显著（控制台独立端口 8080/宿主机 18080、v3 API、10 张表、无内置默认密码、`MYSQL_SERVICE_DB_PARAM`），编排细节以 [SCG 设计文档](2026-08-24-microservices-arch-scg-design.md) §5.1 的实测备注为准——本方案与 C 方案沿用同一基础设施编排。

**nacos**：启动参数同方案 A，但**业务服务不配置 nacos-discovery**——Nacos 仅承担配置中心（保留动态配置热刷新学习主题）。

**kong**（DB-less 模式，零数据库）：
- `KONG_DATABASE=off`、`KONG_DECLARATIVE_CONFIG=/usr/local/kong/declarative/kong.yml`
- 挂载 `kong/kong.yml`；端口 8000（proxy）、8001（admin API）、8002（Kong Manager UI）
- healthcheck：`curl http://localhost:8001/status`

`kong.yml` 声明式配置（阶段 1 要点）：

```yaml
_format_version: "3.0"
services:
  - name: order-service
    url: http://order-service:8081
    routes:
      - name: order-route
        paths: ["/api/order"]
        strip_path: false
        plugins:
          - name: rate-limiting
            config:
              minute: 60          # 限流阈值，可调整
              policy: redis
              redis_host: redis   # 计数存 Redis（基础设施用途）
```

### 5.2 order-service

与方案 A §5.2 基本一致，差异：
- **去掉** `nacos-discovery`，仅保留 `nacos-config`（`spring.config.import: nacos:order-service.yaml`）
- 服务不注册、不需要 `spring-cloud-starter-loadbalancer`
- 接口、Caffeine、MyBatis-Plus、雪花 ID、配置热刷新全部同方案 A

### 5.3 阶段 1 验收标准

1. 全部容器 healthy；`curl http://localhost:8001/services` 可见声明式配置加载
2. `curl http://localhost:8000/api/order/orders` 经 Kong 路由返回 200
3. Kong Manager（`localhost:8002`）可视化查看路由与插件
4. 缓存命中（`X-Cache: HIT`）、限流 429（响应带 `X-RateLimit-*` 头）同方案 A
5. Nacos 修改 `order.cache.ttl` 不重启生效（配置中心职责不变）

## 6. 阶段 2 详细设计

**user-service**（+1 容器）：不注册；`GET /users/{id}`；Kong 配置追加 `/api/user` 路由。

**order-service 增强**：
- 新增 `GET /orders/{id}/user`：用 Spring `RestClient`（Boot 3.5 内置）调 `http://kong:8000/api/user/users/{userId}`——**服务间调用走 Kong**
- **熔断**：Resilience4j 注解直接包这段 HTTP 调用（`resilience4j-spring-boot3` 依赖，`@CircuitBreaker` + `fallbackMethod` 兜底），熔断规则本地 yml 配置
- **服务级限流**：`@RateLimiter` 挂 `GET /orders/{id}`，同方案 A
- 已知限制（如实记录）：**Kong 无原生网关层熔断**，熔断仅存在于调用方（服务端）；如需网关层粗粒度摘除，属方案 C 的 nginx 被动健康检查能力

**阶段 2 验收**：`docker stop user-service` 后 `GET /orders/{id}/user` 返回兜底而非 500；恢复后自动 CLOSED。

## 7. 阶段 3 详细设计

**auth-service**（+1 容器）：`POST /api/auth/login` → BCrypt 校验 → jjwt HS256 签发（与方案 A 相同实现）。路由 `/api/auth` 加入 Kong 配置。

**Kong jwt 插件**（本方案认证核心差异）：
- `/api/auth/login` 路由**不挂** jwt 插件（白名单）；其余路由挂 `jwt` 插件
- `config: { secret_is_base64: false, key_claim_name: iss }`；HS256 共享密钥与 auth-service 签发的 secret **必须一致**（密钥存 Nacos 配置供 auth-service 读，Kong 侧在 `kong.yml` 声明——两处需人工保持一致，列为已知坑）
- 无 token / 校验失败 → Kong 直接返回 401

**rabbitmq + order-service MQ**：与方案 A §7 完全相同（网关不参与，三方案零差异）。

**阶段 3 验收**：无 token 401；login 后带 token 200；消息流转与 status 异步更新同方案 A。

## 8. 数据模型

与方案 A §8 完全相同（`sql/order_db.sql`）。

## 9. 项目目录结构

```
new4/
├── docker-compose.yml
├── .env
├── sql/order_db.sql
├── nacos/mysql-schema.sql
├── kong/kong.yml             # 声明式网关配置（路由/upstream/插件）
├── order-service/
├── user-service/             # 阶段 2
├── auth-service/             # 阶段 3
└── README.md
```

（无 gateway/、无 nginx/ 目录——两者被 Kong 取代）

## 10. 内存预算（估算）

阶段 1 ~3GB（Nacos ~1GB、双 MySQL ~1GB、Kong ~0.5GB、order-service ~0.4GB）→ 阶段 3 ~4GB。WSL2 给 Docker **≥5GB**。

## 11. 已知坑与对策（实施必读）

1. Kong DB-less 声明式配置：修改 `kong.yml` 后需 `kong reload`/重启容器才生效（不同于 Admin API 实时生效）
2. **jwt 插件密钥与 auth-service 签发密钥两处配置，人工对齐**——最容易踩的坑，实施时用同一 Nacos 配置项派生并写清注释
3. rate-limiting 插件 `policy: redis` 需 Kong 容器与 redis 网络互通，且限流计数器 key 按 consumer/IP 需配置 `limit_by`
4. 服务间调用走 Kong：order-service 的 RestClient base-url 写死 `http://kong:8000`（compose 服务名）
5. Nacos 仅配置模式：确认业务服务 pom 里**不引入** nacos-discovery starter，否则启动报注册连接错误
6. 其余 Nacos 3.x 鉴权、mysql-schema 初始化、双 MySQL 密码编码等坑与方案 A §11 相同

## 12. 与其他方案的关系

- 方案 A（SCG）：功能最全、后续阶段咬合最顺（熔断/认证/发现官方一体），实施首选
- 方案 C（OpenResty）：与本方案同为"全流量过网关"单注册模型，但网关层自己写 Lua——组件更少、无 Kong 配置模型要学、但认证双语言实现
- 本方案（B）为设计储备，不进入实施
