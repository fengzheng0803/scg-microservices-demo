# 微服务架构最小集合 · 设计方案 A（Spring Cloud Gateway 体系）

- 日期：2026-08-24
- 状态：**实施首选方案**（其余两份设计见 [Kong 方案](2026-08-24-microservices-arch-kong-design.md)、[OpenResty 方案](2026-08-24-microservices-arch-openresty-design.md)）
- 定位：Spring Cloud 全 Java 闭环，后续阶段（熔断/认证/服务发现）咬合度最高

## 1. 目标与选型原则

**目标**：学习/演示微服务架构——注册中心、配置中心、API 网关、本地缓存、两级限流、熔断降级、认证中心、消息异步。全 Docker Compose 一键启动，每阶段可独立验证。

**选型原则**：组件按自身优劣选择，不以"生态系"为决策依据。本方案选 SCG 的理由是：SCG 的价值核心（`DiscoveryClient` + `ReactiveLoadBalancerClientFilter`）与 Nacos 注册、Feign 熔断、Java 端 JWT 校验三处官方一体，后续阶段落地最顺。代价：网关吞吐低于 OpenResty 系（演示规模无感知）。

## 2. 版本基线

| 组件 | 版本 | 状态 |
|------|------|------|
| JDK | 21（eclipse-temurin） | 确定 |
| Spring Boot | 3.5.x | 确定 |
| Spring Cloud | 2025.0.x | 确定 |
| Spring Cloud Alibaba | 2025.0.0.0 | ✅ 已核实（Nacos Client 3.0.3） |
| Nacos Server | nacos/nacos-server:v3.0.3 | ✅ 已核实（与 Client 3.0.3 严格对应） |
| MyBatis-Plus | 3.5.12（mybatis-plus-spring-boot3-starter） | 实施时锁定 |
| Resilience4j | Spring Cloud 2025.0 BOM 管理 | 确定 |
| MySQL | mysql:8.4 | 实施时锁定 |
| Redis | redis:7-alpine | 实施时锁定 |
| nginx | nginx:alpine | 实施时锁定 |
| RabbitMQ | rabbitmq:3-management | 实施时锁定 |
| JWT | jjwt 0.12.6 | 实施时锁定 |

> 注：标注"实施时锁定"的镜像 tag 在实施计划第一步统一验证后钉死。

## 3. 全景架构（阶段 3 完整形态，共 10 容器）

```
client
  │ :80
  ▼
nginx (边缘层：SSL/静态/分流)          rabbitmq (5672/15672)
  │ :8080                              ▲  ▲
  ▼                                    │  │ ORDER_CREATED
gateway (SCG: JWT校验/Redis令牌桶限流)   │  └─ 消费者(同服务内)
  │ Nacos 发现 + 负载均衡(lb://)         │
  ├──────────────┬──────────────┐      │
  ▼              ▼              ▼      │
order-service  user-service  auth-service
:8081          :8082          :8083
  │ Caffeine      │ MySQL(users)  │ 签发JWT
  ▼               │               ▼
mysql-order(:3306, order_db)   gateway 校验(JWT secret 同源于 Nacos 配置)
  ▲
nacos(:8848/9848) ← 注册中心+配置中心（数据存 mysql-nacos:3307 的 nacos_config 库）
redis(:6379) ← 网关限流令牌桶存储
```

| 容器 | 镜像 | 端口 | 职责 | 加入阶段 |
|------|------|------|------|---------|
| mysql-order | mysql:8.4 | 3306 | 业务库 `order_db` | 1 |
| mysql-nacos | mysql:8.4 | 3307 | Nacos 专属库 `nacos_config` | 1 |
| nacos | nacos/nacos-server:v3.0.3 | 8848/9848/18080 | 注册中心 + 配置中心（18080 为 3.x 控制台 UI） | 1 |
| redis | redis:7-alpine | 6379 | 网关限流令牌桶 | 1 |
| order-service | 自建 | 8081 | 订单服务 | 1 |
| gateway | 自建 | 8080 | API 网关 | 1 |
| nginx | nginx:alpine | 80 | 边缘入口 | 2 |
| user-service | 自建 | 8082 | 用户服务（被调用方） | 2 |
| auth-service | 自建 | 8083 | 认证中心（签发 JWT） | 3 |
| rabbitmq | rabbitmq:3-management | 5672/15672 | 消息异步解耦 | 3 |

- 单一 bridge 网络 `microservices-net`；服务间用 compose 服务名互访
- 依赖顺序（healthcheck 保证）：mysql-order、mysql-nacos → nacos → redis → order-service、gateway →（阶段 2）nginx、user-service →（阶段 3）auth-service、rabbitmq
- 三个业务服务端口对宿主机开放（8081/8082/8083），便于绕过网关直连调试

## 4. 阶段划分

| 阶段 | 新增 | 累计容器 | 学习主题 |
|------|------|---------|---------|
| 1 最小集合 | 双 MySQL、Nacos、Redis、order-service、gateway | 6 | 注册/配置中心、网关路由、本地缓存、网关限流 |
| 2 调用链与弹性 | nginx、user-service；order-service 加 Feign+Resilience4j | 8 | 服务间调用、熔断降级、服务级限流、边缘层 |
| 3 安全与异步 | auth-service、rabbitmq；gateway 加 JWT 过滤；order-service 加 MQ | 10 | 认证、JWT 链路、消息异步解耦 |

**排除项**：Seata（所有阶段完成后单独讨论）；RocketMQ（明确不用）；Sentinel（已选 Resilience4j）；K8s（Compose 足够，作为以后的演进方向）。

## 5. 阶段 1 详细设计

### 5.1 基础设施

**mysql-order**：`MYSQL_ROOT_PASSWORD` 取自 `.env`；`MYSQL_DATABASE=order_db`；挂载 `sql/order_db.sql` 至 `/docker-entrypoint-initdb.d/`（首启自动建表 + 种子数据）；healthcheck：`mysqladmin ping`。

**mysql-nacos**：`MYSQL_DATABASE=nacos_config`（utf8mb4）；挂载 `nacos/mysql-schema.sql`（从 `alibaba/nacos` 仓库 3.0.3 tag 拉取：`distribution/conf/mysql-schema.sql`，11 张表）。

**nacos**（3.0.3 实测形态）：`MODE=standalone`、`SPRING_DATASOURCE_PLATFORM=mysql`、`MYSQL_SERVICE_HOST=mysql-nacos`、`MYSQL_SERVICE_DB_NAME=nacos_config`；**3.x 注意**：① JDBC 参数用 `MYSQL_SERVICE_DB_PARAM`（2.x 的 `MYSQL_SERVICE_PARAM` 无效），必须含 `allowPublicKeyRetrieval=true`（MySQL 8.4 caching_sha2_password）；② 鉴权必配 `NACOS_AUTH_TOKEN`（≥32 字符 Base64）+ `NACOS_AUTH_IDENTITY_KEY/VALUE`；③ **控制台 UI 独立运行在容器 8080**（宿主机映射 18080，8848 不再承载 UI），readiness 在 `8080/v3/console/health/readiness`（v1 路径 410）；④ **3.x 不再内置默认管理员密码**，首次需 `POST /nacos/v3/auth/user/admin` 初始化（持久化 MySQL）；⑤ schema 为 10 张表（移除 2.x 的 config_info_aggr/config_info_beta，新增 config_info_gray）；⑥ 两个 API 入口 contextPath 不同：控制台端口用 `/v3/...`，客户端端口 8848 用 `/nacos/v3/...`。

**redis**：无持久化需求，默认配置即可；healthcheck：`redis-cli ping`。

### 5.2 order-service

依赖：`spring-cloud-starter-alibaba-nacos-discovery`、`spring-cloud-starter-alibaba-nacos-config`、`mybatis-plus-spring-boot3-starter`、`mysql-connector-j`、`spring-boot-starter-cache` + `caffeine`、`spring-boot-starter-actuator`。

关键设计点：
- 配置中心：`application.yml` 中用 `spring.config.import: nacos:order-service.yaml`（SCA 2025 新方式，**不用 bootstrap**）
- **缓存配置下放 Nacos 演示热刷新**：`order.cache.ttl`、`order.cache.max-size` 存于 Nacos，`@ConfigurationProperties` + `@RefreshScope`，改配置不重启生效
- 雪花 ID：MyBatis-Plus `IdType.ASSIGN_ID`
- 写操作后 `@CacheEvict` 清缓存

接口：

| 接口 | 说明 | 演示点 |
|------|------|--------|
| `POST /orders` | 创建订单 | 写路径 + 缓存失效 |
| `GET /orders/{id}` | 查详情，响应头 `X-Cache: HIT/MISS` | Caffeine 本地缓存 + 配置热刷新 |
| `DELETE /orders/{id}` | 删除订单 | `@CacheEvict` |
| `GET /orders` | 分页列表 | MyBatis-Plus 分页插件 |

### 5.3 gateway

依赖：`spring-cloud-starter-gateway`、`spring-cloud-starter-alibaba-nacos-discovery`、`spring-boot-starter-data-redis-reactive`。

- 路由：`/api/order/** → lb://order-service`（Nacos 发现 + Spring Cloud LoadBalancer）
- 限流：`RequestRateLimiter` 过滤器，Redis 令牌桶（`replenishRate`/`burstCapacity`，`KeyResolver` 按 IP）
- 配置同样经 `spring.config.import` 从 Nacos 读取
- 自身也注册进 Nacos（教学点：网关是注册中心里一个平等服务）

### 5.4 阶段 1 验收标准

1. `docker compose up --build -d` 后全部容器 healthy
2. Nacos 控制台 `localhost:18080`（nacos/nacos）看到 order-service、gateway 已注册
3. `curl http://localhost:8080/api/order/orders` 返回 200 列表
4. 创建订单后连续两次查详情：首次 `X-Cache: MISS`，第二次 `X-Cache: HIT`
5. 快速循环 curl 触发 429（Redis 令牌桶生效）
6. Nacos 上修改 `order.cache.ttl`，服务不重启即可生效

## 6. 阶段 2 详细设计

**nginx**（+1 容器）：`nginx/nginx.conf` 中 `upstream gateway:8080`，`location /` 反代；演示边缘层与 API 网关分层（面试高频点）。

**user-service**（+1 容器）：极简，注册 Nacos；`GET /users/{id}` 查 `users` 表。

**order-service 增强**：
- Feign：`spring-cloud-starter-openfeign` + `spring-cloud-starter-loadbalancer`；`UserClient` 经 Nacos 发现调 user-service；新增 `GET /orders/{id}/user`
- **熔断**：`spring-cloud-starter-circuitbreaker-resilience4j` + `feign.circuitbreaker.enabled=true`；`fallbackFactory` 返回兜底响应（"用户信息暂不可用"）
- **服务级限流**：Resilience4j `@RateLimiter` 挂 `GET /orders/{id}`（与网关级限流形成两级对比，参数同样可下放 Nacos）
- 观测：Actuator `/actuator/health` 看 circuitbreaker 状态（OPEN/CLOSED）、`circuitbreakerevents` 端点看状态迁移

**阶段 2 验收**：`docker stop user-service` 后 `GET /orders/{id}/user` 返回兜底而非 500；重启 user-service 后自动恢复 CLOSED；`localhost:80` 经 nginx 转发全链路通。

## 7. 阶段 3 详细设计

**auth-service**（+1 容器）：注册 Nacos；`POST /api/auth/login` {username, password} → BCrypt 校验 `users` 表 → jjwt HS256 签发 token（sub/exp）；**JWT 共享密钥放 Nacos 配置**（`auth.jwt.secret`），auth-service（签发）与 gateway（校验）同源读取。

**gateway 增强**：全局过滤器校验 `Authorization: Bearer`，白名单仅 `/api/auth/login`；无 token / 校验失败 → 401。

**rabbitmq**（+1 容器）：`rabbitmq:3-management`，管理台 15672。

**order-service 增强**（`spring-boot-starter-amqp`）：
- 生产者：创建订单成功后发 `ORDER_CREATED` 消息（orderId/orderNo/amount）
- 消费者：同服务内 `@RabbitListener` 异步处理（模拟订单通知：写日志 + 更新 `orders.status=1`）

**阶段 3 验收**：无 token 访问 401；login 拿 token 后访问 200；创建订单后 RabbitMQ 管理台见消息流转，`orders.status` 异步变为 1。

## 8. 数据模型（三方案共用）

`sql/order_db.sql`（mysql-order 首启执行）：

```sql
CREATE TABLE IF NOT EXISTS orders (
  id            BIGINT PRIMARY KEY,
  order_no      VARCHAR(64) NOT NULL UNIQUE,
  user_id       BIGINT NOT NULL,
  product_name  VARCHAR(128) NOT NULL,
  amount        DECIMAL(10,2) NOT NULL,
  status        TINYINT NOT NULL DEFAULT 0 COMMENT '0=已创建 1=已通知(阶段3消费者更新)',
  create_time   DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS users (
  id        BIGINT PRIMARY KEY AUTO_INCREMENT,
  username  VARCHAR(64) NOT NULL UNIQUE,
  password  VARCHAR(128) NOT NULL COMMENT 'BCrypt',
  nickname  VARCHAR(64),
  create_time DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);
```

种子数据：users 表插入 1~2 个账号（BCrypt 密文在实施时生成）。

## 9. 项目目录结构

```
new4/
├── docker-compose.yml
├── .env                      # 密码、NACOS_AUTH_TOKEN 等参数
├── sql/order_db.sql
├── nacos/mysql-schema.sql    # 从 alibaba/nacos 3.0.3 拉取
├── nginx/nginx.conf          # 阶段 2
├── order-service/            # 独立 Maven 工程 + Dockerfile（多阶段构建）
├── user-service/             # 阶段 2
├── auth-service/             # 阶段 3
├── gateway/                  # 独立 Maven 工程 + Dockerfile
└── README.md                 # 启动步骤 + 验证脚本
```

三个业务服务 + 网关为**独立 Maven 工程**（非父子多模块）：各自 Docker 构建上下文干净，学习时直观。

## 10. 内存预算（估算）

阶段 1 ~3GB（Nacos ~1GB 最大、双 MySQL ~1GB、两服务各 ~0.4GB）→ 阶段 2 ~3.3GB → 阶段 3 ~4GB。WSL2 给 Docker 分配 **≥5GB**。

## 11. 已知坑与对策（实施必读）

1. **Nacos client/server 必须同为 3.0.3**——用 2.x server 读不到配置（已核实，SCA 2025.0.0.0 捆绑 client 3.0.3）
2. SCA 2025 配置一律 `spring.config.import`，不要引入 bootstrap
3. Nacos 3.x 鉴权必配 `NACOS_AUTH_TOKEN`（≥32 字符）+ identity key/value，否则启动异常
4. `RequestRateLimiter` 需要 Redis reactive 依赖 + 自定义 `KeyResolver` bean，缺一个都报错
5. Feign + 熔断必须同时有 circuitbreaker starter 和 `feign.circuitbreaker.enabled=true`
6. MySQL 密码含特殊字符时 JDBC 连接串需 URL 编码
7. compose 用 `depends_on: condition: service_healthy` 保证 Nacos 先于业务服务启动
8. Resilience4j 参数（阈值/窗口）与 Nacos 配置热刷新的兼容性：熔断规则放本地 yml（改阈值即重启），仅业务参数（缓存 TTL 等）走热刷新

## 12. 与其他方案的关系

- 方案 B（Kong）：网关/限流/JWT 由 Kong 承担，Nacos 降级为仅配置中心，无本方案的"网关层熔断"能力
- 方案 C（OpenResty）：nginx+lua 即网关，组件最少性能最强，认证需跨语言双实现
- 本方案（A）为实施首选；B/C 仅为设计储备
