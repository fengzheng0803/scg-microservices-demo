# 微服务架构最小集合 · 设计方案 C（OpenResty 自建网关）

- 日期：2026-08-24
- 状态：**仅设计储备**（当前实施首选为 [SCG 方案](2026-08-24-microservices-arch-scg-design.md)；另一储备见 [Kong 方案](2026-08-24-microservices-arch-kong-design.md)）
- 定位：nginx+lua 即网关——组件最少、网关性能最强、网关机制（路由/限流/JWT）全部自己实现

## 1. 目标与选型原则

**目标**：与方案 A 相同，但追求"不限体系、性能更高、组件更少"的形态。网关层不引入任何现成网关产品（SCG/Kong），用 OpenResty（nginx+lua）直接实现。

**选型原则**：组件按自身优劣选择。选 OpenResty 的理由：与"nginx 里搭配 lua 脚本实现限流"的诉求完全重合（本来就要写 Lua，就不必再叠 SCG 或 Kong）；OpenResty 内核网关吞吐最强；限流/JWT/路由自己实现一遍，学到的正是网关的本质机制。代价：要写 ~100 行 Lua；认证为 Java 签发 + Lua 校验双语言双实现，调试成本最高。

## 2. 版本基线

| 组件 | 版本 | 状态 |
|------|------|------|
| JDK / Boot / Cloud / SCA / Nacos / MyBatis-Plus / MySQL / Redis / RabbitMQ / jjwt | 同方案 A §2 | 同方案 A |
| OpenResty | openresty/openresty:1.25-alpine-fat（实施时锁定具体 tag） | 待锁定 |
| lua-resty-limit-traffic | OpenResty 自带（内存令牌桶备选） | 确定 |
| lua-resty-jwt | SkyLothar/lua-resty-jwt（**需自定义镜像通过 opm 安装**，阶段 3 用） | 待锁定 |
| nginx / SCG / Kong | **均不使用**（OpenResty 即唯一网关） | 确定 |

## 3. 全景架构（阶段 3 完整形态，共 9 容器）

```
client
  │ :80
  ▼
OpenResty (nginx+lua 自定义镜像)
  ├─ 路由: /api/order → upstream order-service:8081
  ├─ 路由: /api/user  → upstream user-service:8082   (max_fails=3 被动健康检查)
  ├─ 限流: lua 脚本 + Redis 计数器 (INCR+EXPIRE 滑动窗口)
  └─ JWT : lua-resty-jwt 校验 (阶段3, 白名单 /api/auth/login)
  ├──────────────┬──────────────┐
  ▼              ▼              ▼
order-service  user-service  auth-service
:8081          :8082          :8083
  │ Caffeine      │ MySQL(users)  │ 签发JWT(HS256)
  │ Resilience4j  │               │
  └─ 服务间调用走网关: http://openresty/api/user/...（单注册模型）
  ▼
mysql-order(:3306)   mysql-nacos(:3307)   redis(:6379)   rabbitmq(:5672)
  ▲                      ▲                    ▲              ▲
  └───── nacos(:8848, 仅配置中心, 服务不注册)──┘   限流计数器       订单 MQ
```

| 容器 | 镜像 | 端口 | 职责 | 加入阶段 |
|------|------|------|------|---------|
| mysql-order | mysql:8.4 | 3306 | 业务库 | 1 |
| mysql-nacos | mysql:8.4 | 3307 | Nacos 配置库 | 1 |
| nacos | nacos/nacos-server:v3.0.3 | 8848/9848 | 仅配置中心 | 1 |
| redis | redis:7-alpine | 6379 | 网关限流计数器 | 1 |
| order-service | 自建 | 8081 | 订单服务（不注册） | 1 |
| openresty | 自建（openresty 基础镜像 + lua 脚本） | 80 | 网关：路由+限流+健康检查+JWT | 1 |
| user-service | 自建 | 8082 | 用户服务（不注册） | 2 |
| auth-service | 自建 | 8083 | 签发 JWT | 3 |
| rabbitmq | rabbitmq:3-management | 5672/15672 | MQ | 3 |

**注册模型**：与方案 B 相同的单注册模型——nginx `upstream` 静态地址（compose 固定地址），服务不自注册、全流量过网关。**本方案额外优势**：nginx 原生被动健康检查（`max_fails`/`fail_timeout`）提供网关层粗粒度"熔断"（连续失败自动摘除上游），是 B 方案（Kong）没有的内置能力。

## 4. 阶段划分

| 阶段 | 新增 | 累计容器 | 学习主题 |
|------|------|---------|---------|
| 1 最小集合 | 双 MySQL、Nacos(仅配置)、Redis、order-service、openresty | 6 | 手写网关路由、手写 Lua 限流、本地缓存 |
| 2 调用链与弹性 | user-service；order-service 加 Resilience4j；openresty 加被动健康检查 | 7 | 服务间调用、熔断（服务端+网关层两级）、服务级限流 |
| 3 安全与异步 | auth-service、rabbitmq；openresty 加 lua-resty-jwt | 9 | 认证、跨语言 JWT 链路、消息异步 |

**排除项**：同方案 A（Seata/RocketMQ/Sentinel/K8s）+ SCG、Kong（被 OpenResty 取代）。

## 5. 阶段 1 详细设计

### 5.1 基础设施

mysql-order、mysql-nacos、redis 与方案 A §5.1 完全相同；nacos 同方案 B（仅配置中心）。

**openresty 自定义镜像**（`openresty/Dockerfile`）：`FROM openresty/openresty:1.25-alpine-fat`，挂载 `openresty/nginx.conf` 与 `openresty/lua/`。

`openresty/nginx.conf` 要点：

```nginx
upstream order_upstream { server order-service:8081; }

server {
  listen 80;
  location /api/order/ {
    access_by_lua_block { require("ratelimit").limit("order", 10) }  # 每秒 10 次
    proxy_pass http://order_upstream;
  }
}
```

**限流脚本 `openresty/lua/ratelimit.lua`（手写 ~25 行）**：Redis `INCR` + `EXPIRE` 滑动窗口计数器（key=`ratelimit:{name}:{ip}:{秒}`），超阈值返回 429。选 Redis 计数而非 lua-resty-limit-traffic 内存桶的理由：演示 Redis 基础设施用途 + 学会限流算法本质（lua-resty-limit-traffic 作为备选库在文档注明）。

### 5.2 order-service

与方案 B §5.2 完全相同：仅 `nacos-config`、不注册、Caffeine/MyBatis-Plus/雪花 ID/配置热刷新同方案 A。

### 5.3 阶段 1 验收标准

1. 全部容器 healthy
2. `curl http://localhost/api/order/orders` 经 OpenResty 路由返回 200
3. 缓存命中（`X-Cache: HIT`）同方案 A
4. 快速循环 curl 触发 429（自写 Lua 限流 + Redis 计数生效，`redis-cli` 可看到计数器 key）
5. Nacos 修改 `order.cache.ttl` 不重启生效

## 6. 阶段 2 详细设计

**user-service**（+1 容器）：不注册；`GET /users/{id}`；nginx.conf 追加 `/api/user` location 与 upstream。

**openresty 增强——网关层熔断（本方案亮点）**：

```nginx
upstream user_upstream {
  server user-service:8082 max_fails=3 fail_timeout=30s;  # 连续 3 次失败摘除 30s
}
```

演示"网关层粗粒度熔断"：连续调用失败后上游被自动摘除，期间请求直接 502/备用响应，30s 后自动恢复探测。

**order-service 增强**：与方案 B §6 相同——`RestClient` 调 `http://openresty/api/user/users/{userId}`（走网关），Resilience4j `@CircuitBreaker` + `fallbackMethod` 服务端细粒度熔断，`@RateLimiter` 服务级限流。

**阶段 2 验收**：停 user-service 后 `GET /orders/{id}/user` 返回兜底（服务端熔断）；连续失败触发 nginx 摘除（网关层熔断，观察 error.log）；恢复后两级熔断均自动复位。

## 7. 阶段 3 详细设计

**auth-service**（+1 容器）：与方案 A/B 相同（jjwt HS256 签发，密钥存 Nacos 配置）。

**openresty 增强——lua-resty-jwt 校验**：
- 自定义镜像构建时 `opm get SkyLothar/lua-resty-jwt`（写入 Dockerfile）
- `openresty/lua/jwt_auth.lua`（~40 行）：解析 `Authorization: Bearer` → `resty.jwt:verify(secret, token)` → 失败返回 401
- 白名单：`/api/auth/login` location 不挂 `access_by_lua` 校验
- **已知坑**：Java 签发与 Lua 校验的 HS256 secret/claims 必须一致（密钥两处配置，与方案 B 同款坑，但校验逻辑自己写、可调试性比 Kong 插件略好）

**rabbitmq + order-service MQ**：与方案 A §7 完全相同。

**阶段 3 验收**：无 token 401；login 后带 token 200；消息流转同方案 A。

## 8. 数据模型

与方案 A §8 完全相同（`sql/order_db.sql`）。

## 9. 项目目录结构

```
new4/
├── docker-compose.yml
├── .env
├── sql/order_db.sql
├── nacos/mysql-schema.sql
├── openresty/
│   ├── Dockerfile              # 基础镜像 + opm 安装 lua-resty-jwt（阶段 3）
│   ├── nginx.conf              # upstream/路由/被动健康检查
│   └── lua/
│       ├── ratelimit.lua       # 阶段 1：Redis 滑动窗口限流
│       └── jwt_auth.lua        # 阶段 3：JWT 校验
├── order-service/
├── user-service/               # 阶段 2
├── auth-service/               # 阶段 3
└── README.md
```

## 10. 内存预算（估算）

阶段 1 ~2.6GB（网关仅 ~50MB，比 A/B 省 ~0.5GB）→ 阶段 3 ~3.7GB。WSL2 给 Docker **≥4.5GB**（三方案中最省）。

## 11. 已知坑与对策（实施必读）

1. **lua-resty-jwt 不在基础镜像内**：必须自定义镜像 + `opm get SkyLothar/lua-resty-jwt`（用 `-alpine-fat` 镜像，`-alpine` 精简版缺 luarocks/opm）
2. Lua 调试成本最高：写 `ngx.log` 定位，error.log 是主战场；`access_by_lua_block` 与 `content_by_lua_block` 阶段语义要分清
3. **JWT 双语言双实现**：Java 签发（jjwt）与 Lua 校验（lua-resty-jwt）的算法/密钥/claims 对齐——实施时写一个"生成测试 token 的脚本"提前自测
4. 自写限流脚本的并发正确性：Redis `INCR` 天然原子，但要注意 key 的过期设置时序（首次 INCR 后设 EXPIRE）
5. nginx 被动健康检查是 per-upstream 粒度，不能替代 per-endpoint 细粒度熔断——文档中明确两级熔断分工
6. 其余 Nacos 3.x 鉴权、mysql-schema、双 MySQL 密码编码等坑与方案 A §11 相同

## 12. 与其他方案的关系

- 方案 A（SCG）：实施首选，全 Java 闭环，后续阶段咬合最顺
- 方案 B（Kong）：与本方案同为单注册模型，但功能靠 Kong 插件（免写 Lua），代价是无网关层熔断、多一个 Kong 组件
- 本方案（C）为设计储备，不进入实施；若日后转向本方案，业务服务代码与 B 几乎零改动（仅 RestClient base-url 指向 OpenResty）
