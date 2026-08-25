# 微服务架构最小集合（SCG 方案）

Spring Cloud Gateway + Nacos 注册/配置 + Caffeine + Redis + 双 MySQL + RabbitMQ 的 Docker Compose 学习演示项目。
设计文档见 `docs/superpowers/specs/`，实施计划见 `docs/superpowers/plans/`。

## 架构

nginx(80) → gateway(8080, Nacos 发现 + Redis 令牌桶限流) → order-service(8081, Caffeine + MyBatis-Plus)
Nacos(8848/9848, 数据存 mysql-nacos:3307) ｜ mysql-order(3306) ｜ redis(6379)

## 快速启动

```bash
cp .env.example .env   # 修改密码与 NACOS_AUTH_TOKEN（openssl rand -hex 32 | base64 生成）
docker compose up --build -d
bash scripts/init-nacos.sh   # 首次/清库后初始化 Nacos 管理员与配置（幂等，可重复执行）
docker compose ps      # 全部 healthy 后继续
bash scripts/verify-phase1.sh
```

## 按需启动（单独验证某个服务）

compose 支持按服务名选择拉起，`depends_on` 自动带上依赖链（无需多个 compose 文件）：

| 场景 | 命令 |
|------|------|
| 全量拉起 | `docker compose up -d --build` |
| 只测 order-service | `docker compose up -d --build order-service`（自动带 mysql-order + nacos） |
| 只测网关链路 | `docker compose up -d --build gateway`（自动带 nacos + redis） |
| 只起基础设施 | `docker compose up -d mysql-order mysql-nacos nacos redis` |

单独调试某个业务服务（断点开发）：基础设施常驻容器，该服务在 IDE 本地运行并指向宿主机端口：

```bash
docker compose up -d mysql-order mysql-nacos nacos redis
mvn spring-boot:run -Dspring-boot.run.arguments="--spring.cloud.nacos.server-addr=localhost:8848 --spring.datasource.url=jdbc:mysql://localhost:3306/order_db"
```

## 常用入口

- Nacos 控制台: http://localhost:18080/ （nacos/nacos；3.x 控制台独立端口，8848 仅承载客户端 API）
- 订单服务: http://localhost:8081/orders
- 网关: http://localhost:8080/api/order/orders
- WSL2 内存建议 ≥5GB

## 阶段进度

- [x] 阶段 1 最小集合：注册/配置中心、网关路由、本地缓存、网关限流
- [ ] 阶段 2 调用链与弹性：nginx、user-service、Feign、熔断、服务级限流
- [ ] 阶段 3 安全与异步：认证中心、JWT、RabbitMQ
