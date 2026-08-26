# 微服务架构最小集合（SCG 方案）

Spring Cloud Gateway + Nacos 注册/配置 + Caffeine + Redis + 双 MySQL + RabbitMQ 的 Docker Compose 学习演示项目。
设计文档见 `docs/superpowers/specs/`，实施计划见 `docs/superpowers/plans/`。

## 架构

nginx(80, OpenResty + lua 按客户端 IP 令牌桶限流 10/s+20) → gateway(8080, Nacos 发现 + Redis 全局兜底限流 40/s+40) → order-service(8081, Caffeine + MyBatis-Plus)
Nacos(8848/9848, 数据存 mysql-nacos:3307) ｜ mysql-order(3306) ｜ redis(6379，nginx 与 gateway 共用限流桶存储)

限流职责分层：**nginx 边缘层按客户端 IP 限流（主，每 IP 10/s + 20 突发）**；**SCG 全局兜底桶（副，全部请求共享 40/s + 40 突发）**——
正常负载（3 客户端 × 10/s = 30/s）低于 40/s 兜底不误伤，绕过 nginx 直连 8080 的洪水仍被兜底封顶。

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
| 只测边缘层 | `docker compose up -d nginx`（自动带 gateway + redis；OpenResty 边缘网关 + lua 按 IP 限流） |
| 拉起客户端容器 | `bash scripts/launch-clients.sh [N]`（默认 3 个独立 IP 客户端，N 可扩展；随后可跑 `bash scripts/verify-ratelimit-clients.sh` 验收限流） |
| 只起基础设施 | `docker compose up -d mysql-order mysql-nacos nacos redis` |

单独调试某个业务服务（断点开发）：基础设施常驻容器，该服务在 IDE 本地运行并指向宿主机端口：

```bash
docker compose up -d mysql-order mysql-nacos nacos redis
mvn spring-boot:run -Dspring-boot.run.arguments="--spring.cloud.nacos.server-addr=localhost:8848 --spring.datasource.url=jdbc:mysql://localhost:3306/order_db"
```

## 常用入口

- 边缘层（nginx）: http://localhost/api/order/orders （用户入口，按 IP 限流 10/s+20）
- Nacos 控制台: http://localhost:18080/ （nacos/nacos；3.x 控制台独立端口，8848 仅承载客户端 API）
- 订单服务: http://localhost:8081/orders
- 网关: http://localhost:8080/api/order/orders （调试入口；全局兜底限流 40/s+40）
- WSL2 内存建议 ≥5GB

### ⚠️ 8080/8081 是调试入口，不是生产形态

本项目把 gateway(8080) 与 order-service(8081) 的端口直接发布到宿主机，是为了**便于逐层调试**
（不经 nginx 直连网关、不经网关直连服务，用于隔离问题出在哪一跳）。

真实生产中用户**只能访问边缘层**（nginx 的 80/443），网关与业务服务不对外暴露：

| 部署形态 | 如何隔离 |
|----------|----------|
| 物理机 / VM | 服务绑内网 IP，或安全组只放行 nginx 所在主机 |
| 云上 | 网关与服务置于私有子网，仅 nginx / ALB 在公有子网 |
| Kubernetes | 服务为 ClusterIP（集群内可达），仅 Ingress 对外 |
| Docker Compose | **删除 gateway / order-service 的 `ports:` 映射**，二者只在 `microservices-net` 内可达 |

即：把 `docker-compose.yml` 中 gateway 与 order-service 的 `ports:` 两行删掉，本项目就是生产端口形态。

## Jenkins CI

本地 Jenkins（独立 compose，按需启停，不随微服务栈启动）跑 `ci/Jenkinsfile` 流水线：
单元测试 → 构建镜像 → 部署 → 系统测试（`ci/tests/`）→ 发布报告。

**环境就绪与手动配置步骤见 [`ci/jenkins/README.md`](ci/jenkins/README.md)**（解锁密码、插件安装、UI 建作业），
仓库根只需知道：启动 Jenkins、在 UI 建一个 SCM Git 指向 `feature/scg-microservices`、Script Path 填 `ci/Jenkinsfile`。

### 流水线 stage 说明

| Stage | 干什么 | 依赖 |
|-------|--------|------|
| Checkout | 同步挂载的宿主仓库到远程分支（ff-only） | 已 push 的 `feature/scg-microservices` |
| 单元测试 | `docker run maven:3.9-eclipse-temurin-21 mvn test`（Jenkins 镜像不装 maven），当前只测 order-service | 容器可访问外网（拉镜像/依赖） |
| 构建镜像 | `docker compose build order-service`（经 docker.sock 操作宿主 daemon） | 上一步通过 |
| 部署/确保栈运行 | `docker compose up -d` + 等阶段 1 六容器 healthy（≤300s） | 构建成功 |
| 系统测试 | 容器内跑 `ci/tests` pytest 套件（9 个用例，BASE_URL=http://gateway:8080） | 六容器 healthy |
| 发布报告 | junit 步骤把 pytest 的 JUnit XML 上到构建页测试趋势 | 系统测试产出 XML |

### 关键实现说明

- Jenkins 容器挂载 `docker.sock` 操作宿主 Docker，但 daemon 只认宿主路径；
  因此 Jenkins compose 把仓库绑定挂载到**容器内宿主同路径**（不是 `/repo`——compose 的相对路径
  经 daemon 解析，挂在别的路径构建必失败），流水线所有 compose/mvn/pytest 都在该路径下操作。
  路径已参数化：`REPO_PATH`（默认 `/home/fengzheng/new4`）是唯一事实源，定义在
  `ci/jenkins/docker-compose.yml` 的插值与 environment 注入；换机器改 `.env` 或导出 `REPO_PATH` 即可，
  流水线文件（`ci/Jenkinsfile` 的 `env.REPO_PATH`）无机器相关字面量。
- 系统测试的 pytest 在 Jenkins 容器内跑，经 `microservices-net` 直连 `http://gateway:8080`（环境变量 `BASE_URL`）。
- `post { always }` 兜底清理测试专用 userId 残留订单，失败不影响构建结果。

## 阶段进度

- [x] 阶段 1 最小集合：注册/配置中心、网关路由、本地缓存、网关限流
- [ ] 阶段 2 调用链与弹性：nginx、user-service、Feign、熔断、服务级限流
- [ ] 阶段 3 安全与异步：认证中心、JWT、RabbitMQ
