# SCG 微服务架构最小集合 · 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 实现 Docker Compose 一键启动的微服务最小集合（SCG 方案）：订单服务 + Nacos 注册/配置 + Gateway + Redis + 双 MySQL，分三阶段演进到含熔断、限流、认证、MQ 的完整演示。

**Architecture:** nginx → Spring Cloud Gateway（Nacos 发现 + Redis 令牌桶限流）→ 业务服务（order/user/auth，注册 Nacos，配置从 Nacos 热刷新）。业务服务为独立 Maven 工程，多阶段 Docker 构建；基础设施（双 MySQL、Nacos、Redis、RabbitMQ）用官方镜像 + healthcheck 编排启动顺序。

**Tech Stack:** Java 21、Spring Boot 3.5.4、Spring Cloud 2025.0.0、Spring Cloud Alibaba 2025.0.0.0、Nacos Server 3.0.3、MyBatis-Plus 3.5.12、Resilience4j、Caffeine、jjwt 0.12.6、RabbitMQ 3-management、MySQL 8.4、Redis 7、nginx 1.27-alpine、Docker Compose v2。

**Spec:** [docs/superpowers/specs/2026-08-24-microservices-arch-scg-design.md](../specs/2026-08-24-microservices-arch-scg-design.md)

## Global Constraints

- 所有 commit message 末尾必须带 `Co-Authored-By: Claude <noreply@anthropic.com>`
- 版本锁定：Boot 3.5.4 / Cloud 2025.0.0 / SCA 2025.0.0.0 / Nacos Server v3.0.3 / MyBatis-Plus 3.5.12 / jjwt 0.12.6 / mysql:8.4 / redis:7-alpine / rabbitmq:3-management / nginx:1.27-alpine / maven:3.9-eclipse-temurin-21 / eclipse-temurin:21-jre
- Nacos Client 3.0.3 ↔ Server v3.0.3 必须严格对应；SCA 2025 配置一律用 `spring.config.import`，**禁止**引入 bootstrap
- 端口约定：nginx 80、gateway 8080、order-service 8081、user-service 8082、auth-service 8083、Nacos 8848/9848（客户端与管理 API，路径前缀 `/nacos/v3/`）+ 18080（3.x 控制台 UI，readiness 在 `/v3/console/health/readiness`，管理 API 请走 8848）、mysql-order 3306、mysql-nacos 3307、Redis 6379、RabbitMQ 5672/15672
- 测试策略：纯单元测试（JUnit 5 + Mockito，不启动 Spring 上下文、不依赖中间件），在 `order-service` 等模块目录下用 `docker run --rm -v "$PWD":/app -w /app maven:3.9-eclipse-temurin-21 mvn -q test` 运行（本机无需装 Maven/JDK）；集成行为用 curl 验收
- 服务间通过 compose 服务名互访（同网络 `microservices-net`）；启动顺序靠 `depends_on: condition: service_healthy`
- 敏感值（MySQL 密码、NACOS_AUTH_TOKEN、JWT 密钥、RabbitMQ 密码）全部走 `.env`（gitignored）+ `.env.example`（提交）；业务服务容器内以环境变量注入
- 代码包名统一 `com.example.<service>`；Java 代码注释用中文，密度与示例一致
- 每阶段结束时必须全栈从零验证（`docker compose down -v && docker compose up --build -d`）

---

# 阶段 1：最小集合（6 容器）

## Task 1: 项目骨架 + 基础设施编排

**Files:**
- Create: `.gitignore`、`.env.example`、`.env`、`sql/order_db.sql`、`nacos/mysql-schema.sql`（下载）、`docker-compose.yml`（仅基础设施）

**Interfaces:**
- Produces: 运行中的 mysql-order(3306, `order_db`)、mysql-nacos(3307, `nacos_config`)、nacos(8848/9848)、redis(6379)；compose 网络名 `microservices-net`；`MYSQL_ROOT_PASSWORD`/`NACOS_AUTH_TOKEN` 环境变量约定（后续所有任务沿用）

- [ ] **Step 1: 创建骨架文件**

`.gitignore`：
```gitignore
.env
target/
*.iml
.idea/
.vscode/
```

`.env.example`：
```bash
MYSQL_ROOT_PASSWORD=change-me
# 终端执行 openssl rand -hex 32 | base64 生成（≥32 字符 Base64 串），粘贴到 .env 中
NACOS_AUTH_TOKEN=change-me-to-a-base64-string-at-least-32-chars
```

生成 `.env`（注意：`.env` 是纯键值文件，不能写 shell 表达式，用命令生成后写入；GNU base64 默认 76 字符换行会破坏键值对，必须 `-w 0`）：
```bash
cp .env.example .env
sed -i 's/^MYSQL_ROOT_PASSWORD=.*/MYSQL_ROOT_PASSWORD=root123456/' .env
NACOS_TOKEN=$(openssl rand -hex 32 | base64 -w 0)
sed -i "s|^NACOS_AUTH_TOKEN=.*|NACOS_AUTH_TOKEN=$NACOS_TOKEN|" .env
```

`sql/order_db.sql`：
```sql
CREATE TABLE IF NOT EXISTS orders (
  id            BIGINT PRIMARY KEY,
  order_no      VARCHAR(64) NOT NULL UNIQUE,
  user_id       BIGINT NOT NULL,
  product_name  VARCHAR(128) NOT NULL,
  amount        DECIMAL(10,2) NOT NULL,
  status        TINYINT NOT NULL DEFAULT 0 COMMENT '0=已创建 1=已通知(阶段3消费者更新)',
  create_time   DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS users (
  id          BIGINT PRIMARY KEY AUTO_INCREMENT,
  username    VARCHAR(64) NOT NULL UNIQUE,
  password    VARCHAR(128) NOT NULL COMMENT 'BCrypt',
  nickname    VARCHAR(64),
  create_time DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- 种子账号：zhangsan，密码 "123456" 的 BCrypt 密文（Spring Security 官方示例值）
-- 若阶段 3 登录失败，按 Task 11 Step 6 的排查路径重新生成密文回填
INSERT INTO users (username, password, nickname) VALUES
('zhangsan', '$2a$10$N.zmdr9k7uOCQb376NoUnuTJ8iAt6Z5EHsM8lE9lBOsl7iKTVEFDa', '张三');
```

- [ ] **Step 2: 下载 Nacos 3.0.3 初始化 SQL**

Run:
```bash
mkdir -p nacos
curl -fsSL -o nacos/mysql-schema.sql \
  https://raw.githubusercontent.com/alibaba/nacos/3.0.3/distribution/conf/mysql-schema.sql
head -5 nacos/mysql-schema.sql
```
Expected: 文件非空，以 SQL 注释开头。若网络不通（GitHub 被墙），浏览器手动下载同 URL 保存到 `nacos/mysql-schema.sql`。

- [ ] **Step 3: 写 docker-compose.yml（仅基础设施部分）**

```yaml
name: microservices

services:
  mysql-order:
    image: mysql:8.4
    container_name: mysql-order
    environment:
      MYSQL_ROOT_PASSWORD: ${MYSQL_ROOT_PASSWORD}
      MYSQL_DATABASE: order_db
    ports:
      - "3306:3306"
    volumes:
      - mysql-order-data:/var/lib/mysql
      - ./sql/order_db.sql:/docker-entrypoint-initdb.d/order_db.sql:ro
    healthcheck:
      test: ["CMD", "mysqladmin", "ping", "-h", "localhost", "-p${MYSQL_ROOT_PASSWORD}"]
      interval: 10s
      timeout: 5s
      retries: 12
    networks: [microservices-net]

  mysql-nacos:
    image: mysql:8.4
    container_name: mysql-nacos
    environment:
      MYSQL_ROOT_PASSWORD: ${MYSQL_ROOT_PASSWORD}
      MYSQL_DATABASE: nacos_config
    ports:
      - "3307:3306"
    volumes:
      - mysql-nacos-data:/var/lib/mysql
      - ./nacos/mysql-schema.sql:/docker-entrypoint-initdb.d/mysql-schema.sql:ro
    healthcheck:
      test: ["CMD", "mysqladmin", "ping", "-h", "localhost", "-p${MYSQL_ROOT_PASSWORD}"]
      interval: 10s
      timeout: 5s
      retries: 12
    networks: [microservices-net]

  nacos:
    image: nacos/nacos-server:v3.0.3
    container_name: nacos
    environment:
      MODE: standalone
      SPRING_DATASOURCE_PLATFORM: mysql
      MYSQL_SERVICE_HOST: mysql-nacos
      MYSQL_SERVICE_PORT: "3306"
      MYSQL_SERVICE_DB_NAME: nacos_config
      MYSQL_SERVICE_USER: root
      MYSQL_SERVICE_PASSWORD: ${MYSQL_ROOT_PASSWORD}
      # 3.x 变量名为 MYSQL_SERVICE_DB_PARAM（2.x 的 MYSQL_SERVICE_PARAM 无效）；
      # allowPublicKeyRetrieval 是 MySQL 8.4 caching_sha2_password 必需
      MYSQL_SERVICE_DB_PARAM: characterEncoding=utf8&connectTimeout=1000&socketTimeout=3000&autoReconnect=true&useSSL=false&allowPublicKeyRetrieval=true&serverTimezone=UTC
      NACOS_AUTH_ENABLE: "true"
      NACOS_AUTH_TOKEN: ${NACOS_AUTH_TOKEN}
      NACOS_AUTH_IDENTITY_KEY: nacos
      NACOS_AUTH_IDENTITY_VALUE: nacos
    ports:
      - "8848:8848"
      - "9848:9848"
      - "18080:8080"   # 3.x 控制台独立运行在容器 8080；宿主机映射 18080（8080 留给 gateway）
    depends_on:
      mysql-nacos:
        condition: service_healthy
    healthcheck:
      # 3.x readiness 迁移到控制台端口 8080 的 v3 路径（v1 路径返回 410）
      test: ["CMD", "curl", "-f", "http://localhost:8080/v3/console/health/readiness"]
      interval: 15s
      timeout: 5s
      retries: 30
      start_period: 90s
    networks: [microservices-net]

  redis:
    image: redis:7-alpine
    container_name: redis
    ports:
      - "6379:6379"
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      timeout: 5s
      retries: 10
    networks: [microservices-net]

networks:
  microservices-net:
    driver: bridge

volumes:
  mysql-order-data:
  mysql-nacos-data:
```

- [ ] **Step 4: 启动基础设施并验证**

Run:
```bash
docker compose up -d
docker compose ps
```
Expected: 4 个容器最终全部 `healthy`（Nacos 首次启动约 1-2 分钟，耐心等待）。

- [ ] **Step 5: 验证数据库初始化与 Nacos 可用**

Run:
```bash
docker exec mysql-order mysql -uroot -proot123456 -e "SHOW TABLES FROM order_db;"
docker exec mysql-nacos mysql -uroot -proot123456 -e "SHOW TABLES FROM nacos_config;"
curl -fs http://localhost:18080/v3/console/health/readiness
```
Expected: `order_db` 含 orders/users 两张表；`nacos_config` 含 config_info 等 **10 张表**（3.0.3 官方 schema 已移除 2.x 的 config_info_aggr/config_info_beta，新增 config_info_gray）；readiness 返回 `{"code":0,...}` 类 JSON。

**初始化 3.x 管理员密码（一次性，持久化在 MySQL）**——3.x 不再内置 nacos/nacos：
```bash
curl -s -X POST 'http://localhost:8848/nacos/v3/auth/user/admin' -d 'password=nacos'
```
Expected: 返回 `{"code":0,...,"data":{"username":"nacos"...}}`。随后浏览器打开 `http://localhost:18080/`（3.x 控制台独立端口，8848 不再承载 UI），用 `nacos/nacos` 登录成功。

- [ ] **Step 6: Commit**

```bash
git add .gitignore .env.example sql/ docker-compose.yml
git commit -m "chore: 基础设施编排（双 MySQL + Nacos 3.0.3 + Redis）

Co-Authored-By: Claude <noreply@anthropic.com>"
```
（`.env` 被 gitignore，不进版本库。）

## Task 2: order-service 工程骨架 + 注册/配置中心接入

**Files:**
- Create: `order-service/pom.xml`、`order-service/Dockerfile`、`order-service/src/main/java/com/example/order/OrderServiceApplication.java`、`order-service/src/main/java/com/example/order/config/MybatisPlusConfig.java`、`order-service/src/main/resources/application.yml`
- Modify: `docker-compose.yml`（追加 order-service 服务）

**Interfaces:**
- Produces: 运行中的 order-service（8081），已注册 Nacos、能读 Nacos 配置 `order-service.yaml`（dataId，group `DEFAULT_GROUP`）；MySQL 数据源可用

- [ ] **Step 1: 写 pom.xml**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0"
         xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
         xsi:schemaLocation="http://maven.apache.org/POM/4.0.0 https://maven.apache.org/xsd/maven-4.0.0.xsd">
  <modelVersion>4.0.0</modelVersion>
  <parent>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-starter-parent</artifactId>
    <version>3.5.4</version>
    <relativePath/>
  </parent>

  <groupId>com.example</groupId>
  <artifactId>order-service</artifactId>
  <version>0.0.1-SNAPSHOT</version>
  <name>order-service</name>

  <properties>
    <java.version>21</java.version>
    <spring-cloud.version>2025.0.0</spring-cloud.version>
    <spring-cloud-alibaba.version>2025.0.0.0</spring-cloud-alibaba.version>
    <mybatis-plus.version>3.5.12</mybatis-plus.version>
  </properties>

  <dependencyManagement>
    <dependencies>
      <dependency>
        <groupId>org.springframework.cloud</groupId>
        <artifactId>spring-cloud-dependencies</artifactId>
        <version>${spring-cloud.version}</version>
        <type>pom</type>
        <scope>import</scope>
      </dependency>
      <dependency>
        <groupId>com.alibaba.cloud</groupId>
        <artifactId>spring-cloud-alibaba-dependencies</artifactId>
        <version>${spring-cloud-alibaba.version}</version>
        <type>pom</type>
        <scope>import</scope>
      </dependency>
      <dependency>
        <groupId>com.baomidou</groupId>
        <artifactId>mybatis-plus-bom</artifactId>
        <version>${mybatis-plus.version}</version>
        <type>pom</type>
        <scope>import</scope>
      </dependency>
    </dependencies>
  </dependencyManagement>

  <dependencies>
    <dependency>
      <groupId>org.springframework.boot</groupId>
      <artifactId>spring-boot-starter-web</artifactId>
    </dependency>
    <dependency>
      <groupId>org.springframework.boot</groupId>
      <artifactId>spring-boot-starter-actuator</artifactId>
    </dependency>
    <dependency>
      <groupId>org.springframework.boot</groupId>
      <artifactId>spring-boot-starter-cache</artifactId>
    </dependency>
    <dependency>
      <groupId>com.github.ben-manes.caffeine</groupId>
      <artifactId>caffeine</artifactId>
    </dependency>
    <dependency>
      <groupId>com.baomidou</groupId>
      <artifactId>mybatis-plus-spring-boot3-starter</artifactId>
    </dependency>
    <!-- 3.5.9+ 分页插件拆分到独立 artifact，PaginationInnerInterceptor 必需（版本由 mybatis-plus-bom 管理） -->
    <dependency>
      <groupId>com.baomidou</groupId>
      <artifactId>mybatis-plus-jsqlparser</artifactId>
    </dependency>
    <dependency>
      <groupId>com.mysql</groupId>
      <artifactId>mysql-connector-j</artifactId>
      <scope>runtime</scope>
    </dependency>
    <dependency>
      <groupId>com.alibaba.cloud</groupId>
      <artifactId>spring-cloud-starter-alibaba-nacos-discovery</artifactId>
    </dependency>
    <dependency>
      <groupId>com.alibaba.cloud</groupId>
      <artifactId>spring-cloud-starter-alibaba-nacos-config</artifactId>
    </dependency>
    <dependency>
      <groupId>org.projectlombok</groupId>
      <artifactId>lombok</artifactId>
      <optional>true</optional>
    </dependency>
    <dependency>
      <groupId>org.springframework.boot</groupId>
      <artifactId>spring-boot-starter-test</artifactId>
      <scope>test</scope>
    </dependency>
  </dependencies>

  <build>
    <plugins>
      <plugin>
        <groupId>org.springframework.boot</groupId>
        <artifactId>spring-boot-maven-plugin</artifactId>
      </plugin>
    </plugins>
  </build>
</project>
```

- [ ] **Step 2: 写 application.yml**

```yaml
server:
  port: 8081

spring:
  application:
    name: order-service
  config:
    import: nacos:order-service.yaml
  cloud:
    nacos:
      server-addr: nacos:8848
      username: nacos
      password: nacos
  datasource:
    driver-class-name: com.mysql.cj.jdbc.Driver
    url: jdbc:mysql://mysql-order:3306/order_db?useUnicode=true&characterEncoding=utf8&serverTimezone=Asia/Shanghai&useSSL=false&allowPublicKeyRetrieval=true
    username: root
    password: ${MYSQL_ROOT_PASSWORD}

mybatis-plus:
  configuration:
    map-underscore-to-camel-case: true

management:
  endpoints:
    web:
      exposure:
        include: health,info

# 本地兜底值；Nacos 的 order-service.yaml 会覆盖（热刷新）
order:
  cache:
    ttl: 60s
    max-size: 100
```

- [ ] **Step 3: 写启动类与配置类**

`order-service/src/main/java/com/example/order/OrderServiceApplication.java`：
```java
package com.example.order;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;

@SpringBootApplication
public class OrderServiceApplication {

    public static void main(String[] args) {
        SpringApplication.run(OrderServiceApplication.class, args);
    }
}
```

`order-service/src/main/java/com/example/order/config/MybatisPlusConfig.java`：
```java
package com.example.order.config;

import com.baomidou.mybatisplus.annotation.DbType;
import com.baomidou.mybatisplus.extension.plugins.MybatisPlusInterceptor;
import com.baomidou.mybatisplus.extension.plugins.inner.PaginationInnerInterceptor;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

@Configuration
public class MybatisPlusConfig {

    /** 分页插件（GET /orders 分页列表用） */
    @Bean
    public MybatisPlusInterceptor mybatisPlusInterceptor() {
        MybatisPlusInterceptor interceptor = new MybatisPlusInterceptor();
        interceptor.addInnerInterceptor(new PaginationInnerInterceptor(DbType.MYSQL));
        return interceptor;
    }
}
```

- [ ] **Step 4: 写 Dockerfile**

`order-service/Dockerfile`：
```dockerfile
FROM maven:3.9-eclipse-temurin-21 AS build
WORKDIR /app
COPY pom.xml .
RUN mvn -q -B dependency:go-offline
COPY src ./src
RUN mvn -q -B package -DskipTests

FROM eclipse-temurin:21-jre
WORKDIR /app
COPY --from=build /app/target/order-service-0.0.1-SNAPSHOT.jar app.jar
EXPOSE 8081
ENTRYPOINT ["java", "-jar", "app.jar"]
```

- [ ] **Step 5: 在 Nacos 发布 order-service.yaml 配置**

Run（Nacos 3.x 的 v3 API：登录 `/nacos/v3/auth/user/login`、发布 `/nacos/v3/admin/cs/config`，参数用 `groupName` 而非 2.x 的 `group`；若 curl 失败，改为浏览器控制台 http://localhost:18080 手动新建配置）：
```bash
TOKEN=$(curl -s -X POST 'http://localhost:8848/nacos/v3/auth/user/login' \
  -d 'username=nacos&password=nacos' | sed 's/.*"accessToken":"\([^"]*\)".*/\1/')
curl -s -X POST 'http://localhost:8848/nacos/v3/admin/cs/config' \
  -H "accessToken: $TOKEN" \
  --data-urlencode 'dataId=order-service.yaml' \
  --data-urlencode 'groupName=DEFAULT_GROUP' \
  --data-urlencode 'content=order:
  cache:
    ttl: 10s
    max-size: 100'
```
Expected: 返回 `{"code":0,...,"data":true}`。浏览器 Nacos 控制台（http://localhost:18080）"配置管理→配置列表"可见 `order-service.yaml`（ttl 设 10s 是为了验收时能等到过期）。

- [ ] **Step 6: compose 追加 order-service 并启动**

在 `docker-compose.yml` 的 `services:` 下追加：
```yaml
  order-service:
    build: ./order-service
    image: microservices/order-service:latest
    container_name: order-service
    environment:
      MYSQL_ROOT_PASSWORD: ${MYSQL_ROOT_PASSWORD}
    ports:
      - "8081:8081"
    depends_on:
      nacos:
        condition: service_healthy
      mysql-order:
        condition: service_healthy
    healthcheck:
      test: ["CMD-SHELL", "bash -c 'exec 3<>/dev/tcp/127.0.0.1/8081' || exit 1"]
      interval: 15s
      timeout: 5s
      retries: 15
      start_period: 60s
    networks: [microservices-net]
```

Run:
```bash
docker compose up -d --build order-service
docker compose ps
```
Expected: order-service 最终 healthy（首次构建镜像约 2-5 分钟）。

- [ ] **Step 7: 验证注册与配置**

Run:
```bash
curl -s http://localhost:8081/actuator/health
TOKEN=$(curl -s -X POST 'http://localhost:8848/nacos/v3/auth/user/login' -d 'username=nacos&password=nacos' | sed 's/.*"accessToken":"\([^"]*\)".*/\1/')
curl -s -H "accessToken: $TOKEN" 'http://localhost:8848/nacos/v1/ns/service/list?pageNo=1&pageSize=10'
```
Expected: health 返回 `{"status":"UP"}`；服务列表含 `order-service`（healthyInstanceCount=1）。**注册验证的权威判据是浏览器控制台** http://localhost:18080 的"服务管理→服务列表"出现 order-service 且健康实例=1；若 v1 ns 接口在 3.x 下返回 410/404，以控制台为准（客户端与注册中心的 API 版本由 SCA client 3.0.3 自动协商，不影响服务注册本身）。

- [ ] **Step 8: Commit**

```bash
git add order-service/ docker-compose.yml
git commit -m "feat: order-service 骨架接入 Nacos 注册与配置中心

Co-Authored-By: Claude <noreply@anthropic.com>"
```

## Task 3: 订单数据层与创建/查询/删除/分页接口

**Files:**
- Create: `order-service/src/main/java/com/example/order/entity/Order.java`、`order-service/src/main/java/com/example/order/mapper/OrderMapper.java`、`order-service/src/main/java/com/example/order/service/OrderService.java`、`order-service/src/main/java/com/example/order/controller/OrderController.java`、`order-service/src/main/java/com/example/order/dto/CreateOrderRequest.java`、`order-service/src/test/java/com/example/order/service/OrderServiceTest.java`

**Interfaces:**
- Consumes: Task 2 的工程骨架与运行环境
- Produces: `OrderService.create(CreateOrderRequest): Order`、`OrderService.get(Long): Order`（可空）、`OrderService.delete(Long)`、`OrderService.list(long,long): IPage<Order>`；HTTP：`POST /orders`（201+Order）、`GET /orders/{id}`（200/404）、`DELETE /orders/{id}`（204）、`GET /orders?page=&size=`（200+IPage）

- [ ] **Step 1: 写失败测试**

`order-service/src/test/java/com/example/order/service/OrderServiceTest.java`：
```java
package com.example.order.service;

import com.example.order.entity.Order;
import com.example.order.mapper.OrderMapper;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.InjectMocks;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;

import java.math.BigDecimal;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

@ExtendWith(MockitoExtension.class)
class OrderServiceTest {

    @Mock
    private OrderMapper orderMapper;

    @InjectMocks
    private OrderService orderService;

    private CreateOrderRequest request;

    @BeforeEach
    void setUp() {
        request = new CreateOrderRequest(1L, "机械键盘", new BigDecimal("399.00"));
    }

    @Test
    void createGeneratesOrderNoAndInsertsWithStatusZero() {
        when(orderMapper.insert(any(Order.class))).thenReturn(1);

        Order created = orderService.create(request);

        assertThat(created.getOrderNo()).startsWith("ORD");
        assertThat(created.getStatus()).isZero();
        assertThat(created.getUserId()).isEqualTo(1L);
        assertThat(created.getAmount()).isEqualByComparingTo("399.00");
        verify(orderMapper).insert(any(Order.class));
    }

    @Test
    void getReturnsOrderFromMapper() {
        Order order = new Order();
        order.setId(100L);
        when(orderMapper.selectById(100L)).thenReturn(order);

        assertThat(orderService.get(100L)).isSameAs(order);
    }

    @Test
    void deleteCallsMapper() {
        orderService.delete(7L);

        verify(orderMapper).deleteById(7L);
    }
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `cd order-service && docker run --rm -v "$PWD":/app -w /app maven:3.9-eclipse-temurin-21 mvn -q test`
Expected: 编译失败（OrderService/CreateOrderRequest/Order 不存在）。

- [ ] **Step 3: 实现实体与 Mapper**

`order-service/src/main/java/com/example/order/entity/Order.java`：
```java
package com.example.order.entity;

import com.baomidou.mybatisplus.annotation.IdType;
import com.baomidou.mybatisplus.annotation.TableId;
import com.baomidou.mybatisplus.annotation.TableName;
import lombok.Data;

import java.math.BigDecimal;
import java.time.LocalDateTime;

/** 订单实体，对应 orders 表 */
@Data
@TableName("orders")
public class Order {

    /** 雪花 ID（MyBatis-Plus ASSIGN_ID） */
    @TableId(type = IdType.ASSIGN_ID)
    private Long id;

    private String orderNo;

    private Long userId;

    private String productName;

    private BigDecimal amount;

    /** 0=已创建 1=已通知 */
    private Integer status;

    private LocalDateTime createTime;
}
```

`order-service/src/main/java/com/example/order/mapper/OrderMapper.java`：
```java
package com.example.order.mapper;

import com.baomidou.mybatisplus.core.mapper.BaseMapper;
import com.example.order.entity.Order;
import org.apache.ibatis.annotations.Mapper;

@Mapper
public interface OrderMapper extends BaseMapper<Order> {
}
```

- [ ] **Step 4: 实现请求 DTO 与 Service**

`order-service/src/main/java/com/example/order/dto/CreateOrderRequest.java`：
```java
package com.example.order.dto;

import java.math.BigDecimal;

/** 创建订单请求体 */
public record CreateOrderRequest(Long userId, String productName, BigDecimal amount) {
}
```

`order-service/src/main/java/com/example/order/service/OrderService.java`：
```java
package com.example.order.service;

import com.baomidou.mybatisplus.core.conditions.query.LambdaQueryWrapper;
import com.baomidou.mybatisplus.extension.plugins.pagination.Page;
import com.example.order.dto.CreateOrderRequest;
import com.example.order.entity.Order;
import com.example.order.mapper.OrderMapper;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;

import java.util.concurrent.ThreadLocalRandom;

@Service
@RequiredArgsConstructor
public class OrderService {

    private final OrderMapper orderMapper;

    /** 创建订单：雪花 ID + 时间戳订单号 */
    public Order create(CreateOrderRequest request) {
        Order order = new Order();
        order.setOrderNo("ORD" + System.currentTimeMillis()
                + ThreadLocalRandom.current().nextInt(1000, 9999));
        order.setUserId(request.userId());
        order.setProductName(request.productName());
        order.setAmount(request.amount());
        order.setStatus(0);
        orderMapper.insert(order);
        return order;
    }

    public Order get(Long id) {
        return orderMapper.selectById(id);
    }

    public void delete(Long id) {
        orderMapper.deleteById(id);
    }

    /** 分页列表，按创建时间倒序 */
    public Page<Order> list(long page, long size) {
        return orderMapper.selectPage(new Page<>(page, size),
                new LambdaQueryWrapper<Order>().orderByDesc(Order::getCreateTime));
    }
}
```

- [ ] **Step 5: 实现 Controller**

`order-service/src/main/java/com/example/order/controller/OrderController.java`：
```java
package com.example.order.controller;

import com.baomidou.mybatisplus.extension.plugins.pagination.Page;
import com.example.order.dto.CreateOrderRequest;
import com.example.order.entity.Order;
import com.example.order.service.OrderService;
import lombok.RequiredArgsConstructor;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;

@RestController
@RequestMapping("/orders")
@RequiredArgsConstructor
public class OrderController {

    private final OrderService orderService;

    @PostMapping
    @ResponseStatus(HttpStatus.CREATED)
    public Order create(@RequestBody CreateOrderRequest request) {
        return orderService.create(request);
    }

    @GetMapping("/{id}")
    public ResponseEntity<Order> get(@PathVariable Long id) {
        Order order = orderService.get(id);
        if (order == null) {
            return ResponseEntity.notFound().build();
        }
        return ResponseEntity.ok(order);
    }

    @DeleteMapping("/{id}")
    @ResponseStatus(HttpStatus.NO_CONTENT)
    public void delete(@PathVariable Long id) {
        orderService.delete(id);
    }

    @GetMapping
    public Page<Order> list(@RequestParam(defaultValue = "1") long page,
                            @RequestParam(defaultValue = "10") long size) {
        return orderService.list(page, size);
    }
}
```

- [ ] **Step 6: 运行测试确认通过**

Run: `cd order-service && docker run --rm -v "$PWD":/app -w /app maven:3.9-eclipse-temurin-21 mvn -q test`
Expected: 3 个测试全 PASS。

- [ ] **Step 7: 重建容器并 curl 验证**

Run:
```bash
docker compose up -d --build order-service
ID=$(curl -s -X POST http://localhost:8081/orders \
  -H 'Content-Type: application/json' \
  -d '{"userId":1,"productName":"机械键盘","amount":399.00}' | sed 's/.*"id":\([0-9]*\).*/\1/')
echo "order id=$ID"
curl -s http://localhost:8081/orders/$ID
curl -s "http://localhost:8081/orders?page=1&size=5"
curl -s -o /dev/null -w "%{http_code}\n" -X DELETE http://localhost:8081/orders/$ID
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:8081/orders/$ID
```
Expected: 创建返回含雪花 ID 的 JSON；详情查询 200；分页 200；删除 204；删除后再查 404。

- [ ] **Step 8: Commit**

```bash
git add order-service/
git commit -m "feat: 订单 CRUD 接口（MyBatis-Plus + 雪花 ID + 分页）

Co-Authored-By: Claude <noreply@anthropic.com>"
```

## Task 4: Caffeine 本地缓存 + Nacos 配置热刷新

**Files:**
- Create: `order-service/src/main/java/com/example/order/config/CacheConfig.java`、`order-service/src/main/java/com/example/order/config/OrderCacheProperties.java`、`order-service/src/test/java/com/example/order/config/CacheConfigTest.java`
- Modify: `order-service/src/main/java/com/example/order/service/OrderService.java`（@Cacheable/@CacheEvict）、`order-service/src/main/java/com/example/order/controller/OrderController.java`（X-Cache 响应头）

**Interfaces:**
- Consumes: Task 3 的 OrderService/OrderController
- Produces: 缓存名 `orders`（`CacheManager.getCache("orders")` 供 Controller 判命中）；`order.cache.ttl`/`order.cache.max-size` 从 Nacos 热刷新

- [ ] **Step 1: 写失败测试**

`order-service/src/test/java/com/example/order/config/CacheConfigTest.java`：
```java
package com.example.order.config;

import com.example.order.entity.Order;
import org.junit.jupiter.api.Test;
import org.springframework.cache.Cache;
import org.springframework.cache.CacheManager;

import static org.assertj.core.api.Assertions.assertThat;

class CacheConfigTest {

    private final CacheConfig cacheConfig = new CacheConfig();

    @Test
    void cacheHitsAfterPut() {
        OrderCacheProperties props = new OrderCacheProperties();
        CacheManager cacheManager = cacheConfig.cacheManager(props);
        Cache cache = cacheManager.getCache("orders");
        Order order = new Order();
        order.setId(1L);

        cache.put(1L, order);

        assertThat(cache.get(1L)).isNotNull();
    }

    @Test
    void maxSizeFromPropertiesEvictsOldest() {
        OrderCacheProperties props = new OrderCacheProperties();
        props.setMaxSize(1);
        Cache cache = cacheConfig.cacheManager(props).getCache("orders");
        Order first = new Order();
        first.setId(1L);
        Order second = new Order();
        second.setId(2L);

        cache.put(1L, first);
        cache.put(2L, second);
        // Caffeine 容量驱逐异步执行，同步 cleanUp 后再断言
        ((Cache) cache.getNativeCache()).cleanUp();

        assertThat(cache.get(1L)).isNull();
        assertThat(cache.get(2L)).isNotNull();
    }
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `cd order-service && docker run --rm -v "$PWD":/app -w /app maven:3.9-eclipse-temurin-21 mvn -q test`
Expected: 编译失败（CacheConfig/OrderCacheProperties 不存在）。

- [ ] **Step 3: 实现缓存配置**

`order-service/src/main/java/com/example/order/config/OrderCacheProperties.java`：
```java
package com.example.order.config;

import lombok.Data;
import org.springframework.boot.context.properties.ConfigurationProperties;

import java.time.Duration;

/** 订单缓存参数，来源于 Nacos（order-service.yaml）并支持热刷新 */
@Data
@ConfigurationProperties(prefix = "order.cache")
public class OrderCacheProperties {

    /** 缓存过期时间 */
    private Duration ttl = Duration.ofSeconds(60);

    /** 最大条目数 */
    private int maxSize = 100;
}
```

`order-service/src/main/java/com/example/order/config/CacheConfig.java`：
```java
package com.example.order.config;

import com.github.benmanes.caffeine.cache.Caffeine;
import org.springframework.boot.context.properties.ConfigurationProperties;
import org.springframework.cache.CacheManager;
import org.springframework.cache.annotation.EnableCaching;
import org.springframework.cache.caffeine.CaffeineCacheManager;
import org.springframework.cloud.context.config.annotation.RefreshScope;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

@Configuration
@EnableCaching
public class CacheConfig {

    @Bean
    @ConfigurationProperties(prefix = "order.cache")
    public OrderCacheProperties orderCacheProperties() {
        return new OrderCacheProperties();
    }

    /**
     * @RefreshScope 放在 @Bean 方法上：Nacos 配置变更刷新事件触发时
     * 会用新参数重建 CacheManager，实现缓存 TTL/容量热刷新
     */
    @Bean
    @RefreshScope
    public CacheManager cacheManager(OrderCacheProperties properties) {
        CaffeineCacheManager manager = new CaffeineCacheManager("orders");
        manager.setCaffeine(Caffeine.newBuilder()
                .expireAfterWrite(properties.getTtl())
                .maximumSize(properties.getMaxSize()));
        return manager;
    }
}
```

- [ ] **Step 4: Service 加缓存注解，Controller 加命中头**

`OrderService` 中修改两个方法（其余不变）：
```java
    @Cacheable(cacheNames = "orders", key = "#id")
    public Order get(Long id) {
        return orderMapper.selectById(id);
    }

    @CacheEvict(cacheNames = "orders", key = "#id")
    public void delete(Long id) {
        orderMapper.deleteById(id);
    }
```
并在类顶部补充 import：
```java
import org.springframework.cache.annotation.Cacheable;
import org.springframework.cache.annotation.CacheEvict;
```

`OrderController` 的 get 方法替换为（并注入 `CacheManager`）：
```java
    private final CacheManager cacheManager;

    @GetMapping("/{id}")
    public ResponseEntity<Order> get(@PathVariable Long id) {
        Cache cache = cacheManager.getCache("orders");
        boolean hit = cache != null && cache.get(id) != null;
        Order order = orderService.get(id);
        if (order == null) {
            return ResponseEntity.notFound().build();
        }
        return ResponseEntity.ok()
                .header("X-Cache", hit ? "HIT" : "MISS")
                .body(order);
    }
```
补充 import：
```java
import org.springframework.cache.Cache;
import org.springframework.cache.CacheManager;
```

- [ ] **Step 5: 运行测试确认通过**

Run: `cd order-service && docker run --rm -v "$PWD":/app -w /app maven:3.9-eclipse-temurin-21 mvn -q test`
Expected: 全部 PASS（含 Task 3 的 3 个）。

- [ ] **Step 6: 重建并 curl 验证缓存命中**

Run:
```bash
docker compose up -d --build order-service
ID=$(curl -s -X POST http://localhost:8081/orders -H 'Content-Type: application/json' \
  -d '{"userId":1,"productName":"鼠标","amount":99.00}' | sed 's/.*"id":\([0-9]*\).*/\1/')
echo "== 第一次（应 MISS）=="
curl -si http://localhost:8081/orders/$ID | grep -i 'x-cache\|HTTP/'
echo "== 第二次（应 HIT）=="
curl -si http://localhost:8081/orders/$ID | grep -i 'x-cache\|HTTP/'
echo "== 等 11 秒（Nacos 配的 ttl=10s）=="
sleep 11
curl -si http://localhost:8081/orders/$ID | grep -i 'x-cache\|HTTP/'
echo "== 删除后缓存失效 =="
curl -s -o /dev/null -X DELETE http://localhost:8081/orders/$ID
curl -si http://localhost:8081/orders/$ID | grep -i 'x-cache\|HTTP/'
```
Expected: MISS → HIT →（11 秒后）MISS →（删除后）404 且无 HIT。

- [ ] **Step 7: 验证 Nacos 热刷新**

Run（把 ttl 从 10s 改成 3s，Nacos 控制台 http://localhost:18080 操作或 v3 API）：
```bash
TOKEN=$(curl -s -X POST 'http://localhost:8848/nacos/v3/auth/user/login' -d 'username=nacos&password=nacos' | sed 's/.*"accessToken":"\([^"]*\)".*/\1/')
curl -s -X POST 'http://localhost:8848/nacos/v3/admin/cs/config' -H "accessToken: $TOKEN" \
  --data-urlencode 'dataId=order-service.yaml' --data-urlencode 'groupName=DEFAULT_GROUP' \
  --data-urlencode 'content=order:
  cache:
    ttl: 3s
    max-size: 100'
# 等 5 秒让配置推送
ID2=$(curl -s -X POST http://localhost:8081/orders -H 'Content-Type: application/json' \
  -d '{"userId":1,"productName":"硬盘","amount":599.00}' | sed 's/.*"id":\([0-9]*\).*/\1/')
curl -si http://localhost:8081/orders/$ID2 | grep -i x-cache
sleep 4
curl -si http://localhost:8081/orders/$ID2 | grep -i x-cache
```
Expected: 服务**未重启**的情况下，缓存过期从 10s 变为 3s（4 秒后第二次查询 MISS）。

- [ ] **Step 8: Commit**

```bash
git add order-service/
git commit -m "feat: Caffeine 订单详情缓存 + Nacos 配置热刷新

Co-Authored-By: Claude <noreply@anthropic.com>"
```

## Task 5: gateway 工程（Nacos 发现路由 + Redis 令牌桶限流）

**Files:**
- Create: `gateway/pom.xml`、`gateway/Dockerfile`、`gateway/src/main/java/com/example/gateway/GatewayApplication.java`、`gateway/src/main/java/com/example/gateway/config/RateLimiterConfig.java`、`gateway/src/main/resources/application.yml`
- Modify: `docker-compose.yml`（追加 gateway 服务）

**Interfaces:**
- Consumes: Nacos（服务发现）、Redis（限流计数）、Task 2/3 的 order-service 实例
- Produces: `GET/POST/DELETE /api/order/**` → `lb://order-service`；按 IP 限流（超限 429）

- [ ] **Step 1: 写 gateway 工程文件**

`gateway/pom.xml`：
```xml
<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0"
         xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
         xsi:schemaLocation="http://maven.apache.org/POM/4.0.0 https://maven.apache.org/xsd/maven-4.0.0.xsd">
  <modelVersion>4.0.0</modelVersion>
  <parent>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-starter-parent</artifactId>
    <version>3.5.4</version>
    <relativePath/>
  </parent>

  <groupId>com.example</groupId>
  <artifactId>gateway</artifactId>
  <version>0.0.1-SNAPSHOT</version>
  <name>gateway</name>

  <properties>
    <java.version>21</java.version>
    <spring-cloud.version>2025.0.0</spring-cloud.version>
    <spring-cloud-alibaba.version>2025.0.0.0</spring-cloud-alibaba.version>
  </properties>

  <dependencyManagement>
    <dependencies>
      <dependency>
        <groupId>org.springframework.cloud</groupId>
        <artifactId>spring-cloud-dependencies</artifactId>
        <version>${spring-cloud.version}</version>
        <type>pom</type>
        <scope>import</scope>
      </dependency>
      <dependency>
        <groupId>com.alibaba.cloud</groupId>
        <artifactId>spring-cloud-alibaba-dependencies</artifactId>
        <version>${spring-cloud-alibaba.version}</version>
        <type>pom</type>
        <scope>import</scope>
      </dependency>
    </dependencies>
  </dependencyManagement>

  <dependencies>
    <dependency>
      <groupId>org.springframework.cloud</groupId>
      <artifactId>spring-cloud-starter-gateway</artifactId>
    </dependency>
    <dependency>
      <groupId>com.alibaba.cloud</groupId>
      <artifactId>spring-cloud-starter-alibaba-nacos-discovery</artifactId>
    </dependency>
    <dependency>
      <groupId>org.springframework.boot</groupId>
      <artifactId>spring-boot-starter-data-redis-reactive</artifactId>
    </dependency>
    <dependency>
      <groupId>org.springframework.boot</groupId>
      <artifactId>spring-boot-starter-actuator</artifactId>
    </dependency>
    <dependency>
      <groupId>org.springframework.boot</groupId>
      <artifactId>spring-boot-starter-test</artifactId>
      <scope>test</scope>
    </dependency>
  </dependencies>

  <build>
    <plugins>
      <plugin>
        <groupId>org.springframework.boot</groupId>
        <artifactId>spring-boot-maven-plugin</artifactId>
      </plugin>
    </plugins>
  </build>
</project>
```

`gateway/src/main/resources/application.yml`：
```yaml
server:
  port: 8080

spring:
  application:
    name: gateway
  config:
    import: nacos:gateway.yaml
  cloud:
    nacos:
      server-addr: nacos:8848
      username: nacos
      password: nacos
    gateway:
      routes:
        - id: order-service
          uri: lb://order-service
          predicates:
            - Path=/api/order/**
          filters:
            - StripPrefix=1      # /api/order/orders -> order-service 的 /orders
      default-filters:
        - name: RequestRateLimiter
          args:
            redis-rate-limiter.replenishRate: 10
            redis-rate-limiter.burstCapacity: 20
            key-resolver: "#{@ipKeyResolver}"
  data:
    redis:
      host: redis
      port: 6379

management:
  endpoints:
    web:
      exposure:
        include: health,info
```

`gateway/src/main/java/com/example/gateway/GatewayApplication.java`：
```java
package com.example.gateway;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;

@SpringBootApplication
public class GatewayApplication {

    public static void main(String[] args) {
        SpringApplication.run(GatewayApplication.class, args);
    }
}
```

`gateway/src/main/java/com/example/gateway/config/RateLimiterConfig.java`：
```java
package com.example.gateway.config;

import org.springframework.cloud.gateway.filter.ratelimit.KeyResolver;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import reactor.core.publisher.Mono;

@Configuration
public class RateLimiterConfig {

    /** 限流维度：按客户端 IP */
    @Bean
    public KeyResolver ipKeyResolver() {
        return exchange -> {
            var remote = exchange.getRequest().getRemoteAddress();
            String ip = remote != null ? remote.getAddress().getHostAddress() : "unknown";
            return Mono.just(ip);
        };
    }
}
```

`gateway/Dockerfile`（注意 jar 名）：
```dockerfile
FROM maven:3.9-eclipse-temurin-21 AS build
WORKDIR /app
COPY pom.xml .
RUN mvn -q -B dependency:go-offline
COPY src ./src
RUN mvn -q -B package -DskipTests

FROM eclipse-temurin:21-jre
WORKDIR /app
COPY --from=build /app/target/gateway-0.0.1-SNAPSHOT.jar app.jar
EXPOSE 8080
ENTRYPOINT ["java", "-jar", "app.jar"]
```

- [ ] **Step 2: 在 Nacos 发布 gateway.yaml**

Run:
```bash
TOKEN=$(curl -s -X POST 'http://localhost:8848/nacos/v3/auth/user/login' -d 'username=nacos&password=nacos' | sed 's/.*"accessToken":"\([^"]*\)".*/\1/')
curl -s -X POST 'http://localhost:8848/nacos/v3/admin/cs/config' -H "accessToken: $TOKEN" \
  --data-urlencode 'dataId=gateway.yaml' --data-urlencode 'groupName=DEFAULT_GROUP' \
  --data-urlencode 'content=logging:
  level:
    org.springframework.cloud.gateway: INFO'
```
Expected: 返回 `{"code":0,...,"data":true}`。

- [ ] **Step 3: compose 追加 gateway 并启动**

```yaml
  gateway:
    build: ./gateway
    image: microservices/gateway:latest
    container_name: gateway
    ports:
      - "8080:8080"
    depends_on:
      nacos:
        condition: service_healthy
      redis:
        condition: service_healthy
    healthcheck:
      test: ["CMD-SHELL", "bash -c 'exec 3<>/dev/tcp/127.0.0.1/8080' || exit 1"]
      interval: 15s
      timeout: 5s
      retries: 15
      start_period: 60s
    networks: [microservices-net]
```

Run:
```bash
docker compose up -d --build gateway
docker compose ps
```
Expected: gateway healthy。Nacos 控制台服务列表出现 `gateway`。

- [ ] **Step 4: 验证路由与限流**

Run:
```bash
ID=$(curl -s -X POST http://localhost:8080/api/order/orders -H 'Content-Type: application/json' \
  -d '{"userId":1,"productName":"显示器","amount":1299.00}' | sed 's/.*"id":\([0-9]*\).*/\1/')
curl -s http://localhost:8080/api/order/orders/$ID
echo ""
echo "== 快速 25 连发（限流 10/s，应出现 429）=="
for i in $(seq 1 25); do curl -s -o /dev/null -w "%{http_code} " http://localhost:8080/api/order/orders; done; echo
```
Expected: 创建/查询经网关 200 正常；25 连发中出现 `429`（请求太快时甚至可能全部 429）。

- [ ] **Step 5: Commit**

```bash
git add gateway/ docker-compose.yml
git commit -m "feat: gateway 经 Nacos 发现路由 + Redis 令牌桶限流

Co-Authored-By: Claude <noreply@anthropic.com>"
```

## Task 6: 阶段 1 验收脚本 + README + 全量从零验证

**Files:**
- Create: `scripts/verify-phase1.sh`、`README.md`

**Interfaces:**
- Consumes: Task 1-5 全部产物
- Produces: 阶段 1 里程碑（6 容器全栈一键启动 + 自动验收）

- [ ] **Step 1: 写验收脚本**

`scripts/verify-phase1.sh`：
```bash
#!/usr/bin/env bash
# 阶段 1 验收：在 compose 全栈启动后执行
set -euo pipefail
BASE=http://localhost:8080
GATEWAY=http://localhost:8080

echo "== 1. 容器状态 =="
docker compose ps

echo "== 2. Nacos 服务注册 =="
TOKEN=$(curl -s -X POST 'http://localhost:8848/nacos/v3/auth/user/login' -d 'username=nacos&password=nacos' | sed 's/.*"accessToken":"\([^"]*\)".*/\1/')
curl -s -H "accessToken: $TOKEN" 'http://localhost:8848/nacos/v1/ns/service/list?pageNo=1&pageSize=10' || true
echo ""

echo "== 3. 经网关创建订单 =="
CREATE=$(curl -s -X POST $BASE/api/order/orders -H 'Content-Type: application/json' \
  -d '{"userId":1,"productName":"验收商品","amount":88.00}')
echo "$CREATE"
ID=$(echo "$CREATE" | sed 's/.*"id":\([0-9]*\).*/\1/')
[ -n "$ID" ] && [ "$ID" != "$CREATE" ] || { echo "FAIL: 未解析到订单 ID"; exit 1; }

echo "== 4. 缓存命中（第一次 MISS，第二次 HIT）=="
curl -si $BASE/api/order/orders/$ID | grep -i 'x-cache\|HTTP/' || true
curl -si $BASE/api/order/orders/$ID | grep -i 'x-cache\|HTTP/' || true

echo "== 5. 网关限流（快速连发，预期出现 429）=="
for i in $(seq 1 25); do curl -s -o /dev/null -w "%{http_code} " $BASE/api/order/orders; done; echo

echo "== 6. 网关与订单服务健康 =="
curl -s $GATEWAY/actuator/health; echo
curl -s http://localhost:8081/actuator/health; echo

echo "== 阶段 1 验收完成 =="
```

- [ ] **Step 2: 写 README（阶段 1 部分）**

```markdown
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
docker compose ps      # 全部 healthy 后继续
bash scripts/verify-phase1.sh
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
```

- [ ] **Step 3: 全量从零验收**

Run:
```bash
docker compose down -v
docker compose up --build -d
docker compose ps
bash scripts/verify-phase1.sh
```
Expected: 6 容器全部 healthy；脚本 6 项检查通过（MISS→HIT、出现 429、健康 UP、Nacos 服务列表含 order-service 与 gateway）。

- [ ] **Step 4: Commit**

```bash
git add scripts/ README.md
git commit -m "docs: 阶段1验收脚本与README

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

# 阶段 2：调用链与弹性（+2 容器，共 8）

## Task 7: user-service（users 表查询 + Nacos 注册）

**Files:**
- Create: `user-service/pom.xml`、`user-service/Dockerfile`、`user-service/src/main/resources/application.yml`、`user-service/src/main/java/com/example/user/UserServiceApplication.java`、`user-service/src/main/java/com/example/user/entity/User.java`、`user-service/src/main/java/com/example/user/mapper/UserMapper.java`、`user-service/src/main/java/com/example/user/service/UserService.java`、`user-service/src/main/java/com/example/user/controller/UserController.java`、`user-service/src/test/java/com/example/user/service/UserServiceTest.java`
- Modify: `docker-compose.yml`（追加 user-service）

**Interfaces:**
- Consumes: mysql-order 的 users 表（种子账号 zhangsan/123456）
- Produces: `GET /users/{id}` → 200 User（含 id/username/nickname）/ 404；服务名 `user-service`（Feign 调用目标）

- [ ] **Step 1: 写失败测试**

`user-service/src/test/java/com/example/user/service/UserServiceTest.java`：
```java
package com.example.user.service;

import com.example.user.entity.User;
import com.example.user.mapper.UserMapper;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.InjectMocks;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.when;

@ExtendWith(MockitoExtension.class)
class UserServiceTest {

    @Mock
    private UserMapper userMapper;

    @InjectMocks
    private UserService userService;

    @Test
    void getReturnsUserFromMapper() {
        User user = new User();
        user.setId(1L);
        user.setUsername("zhangsan");
        when(userMapper.selectById(1L)).thenReturn(user);

        assertThat(userService.get(1L)).isSameAs(user);
    }
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `cd user-service && docker run --rm -v "$PWD":/app -w /app maven:3.9-eclipse-temurin-21 mvn -q test`
Expected: 编译失败。

- [ ] **Step 3: 写工程文件**

`user-service/pom.xml`（与 order-service 差异：artifactId/name 为 user-service，无 cache/caffeine 依赖）：
```xml
<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0"
         xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
         xsi:schemaLocation="http://maven.apache.org/POM/4.0.0 https://maven.apache.org/xsd/maven-4.0.0.xsd">
  <modelVersion>4.0.0</modelVersion>
  <parent>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-starter-parent</artifactId>
    <version>3.5.4</version>
    <relativePath/>
  </parent>

  <groupId>com.example</groupId>
  <artifactId>user-service</artifactId>
  <version>0.0.1-SNAPSHOT</version>
  <name>user-service</name>

  <properties>
    <java.version>21</java.version>
    <spring-cloud.version>2025.0.0</spring-cloud.version>
    <spring-cloud-alibaba.version>2025.0.0.0</spring-cloud-alibaba.version>
    <mybatis-plus.version>3.5.12</mybatis-plus.version>
  </properties>

  <dependencyManagement>
    <dependencies>
      <dependency>
        <groupId>org.springframework.cloud</groupId>
        <artifactId>spring-cloud-dependencies</artifactId>
        <version>${spring-cloud.version}</version>
        <type>pom</type>
        <scope>import</scope>
      </dependency>
      <dependency>
        <groupId>com.alibaba.cloud</groupId>
        <artifactId>spring-cloud-alibaba-dependencies</artifactId>
        <version>${spring-cloud-alibaba.version}</version>
        <type>pom</type>
        <scope>import</scope>
      </dependency>
      <dependency>
        <groupId>com.baomidou</groupId>
        <artifactId>mybatis-plus-bom</artifactId>
        <version>${mybatis-plus.version}</version>
        <type>pom</type>
        <scope>import</scope>
      </dependency>
    </dependencies>
  </dependencyManagement>

  <dependencies>
    <dependency>
      <groupId>org.springframework.boot</groupId>
      <artifactId>spring-boot-starter-web</artifactId>
    </dependency>
    <dependency>
      <groupId>org.springframework.boot</groupId>
      <artifactId>spring-boot-starter-actuator</artifactId>
    </dependency>
    <dependency>
      <groupId>com.baomidou</groupId>
      <artifactId>mybatis-plus-spring-boot3-starter</artifactId>
    </dependency>
    <dependency>
      <groupId>com.mysql</groupId>
      <artifactId>mysql-connector-j</artifactId>
      <scope>runtime</scope>
    </dependency>
    <dependency>
      <groupId>com.alibaba.cloud</groupId>
      <artifactId>spring-cloud-starter-alibaba-nacos-discovery</artifactId>
    </dependency>
    <dependency>
      <groupId>org.projectlombok</groupId>
      <artifactId>lombok</artifactId>
      <optional>true</optional>
    </dependency>
    <dependency>
      <groupId>org.springframework.boot</groupId>
      <artifactId>spring-boot-starter-test</artifactId>
      <scope>test</scope>
    </dependency>
  </dependencies>

  <build>
    <plugins>
      <plugin>
        <groupId>org.springframework.boot</groupId>
        <artifactId>spring-boot-maven-plugin</artifactId>
      </plugin>
    </plugins>
  </build>
</project>
```

`user-service/src/main/resources/application.yml`：
```yaml
server:
  port: 8082

spring:
  application:
    name: user-service
  cloud:
    nacos:
      server-addr: nacos:8848
      username: nacos
      password: nacos
  datasource:
    driver-class-name: com.mysql.cj.jdbc.Driver
    url: jdbc:mysql://mysql-order:3306/order_db?useUnicode=true&characterEncoding=utf8&serverTimezone=Asia/Shanghai&useSSL=false&allowPublicKeyRetrieval=true
    username: root
    password: ${MYSQL_ROOT_PASSWORD}

mybatis-plus:
  configuration:
    map-underscore-to-camel-case: true

management:
  endpoints:
    web:
      exposure:
        include: health,info
```

`user-service/src/main/java/com/example/user/UserServiceApplication.java`：
```java
package com.example.user;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;

@SpringBootApplication
public class UserServiceApplication {

    public static void main(String[] args) {
        SpringApplication.run(UserServiceApplication.class, args);
    }
}
```

`user-service/src/main/java/com/example/user/entity/User.java`：
```java
package com.example.user.entity;

import com.baomidou.mybatisplus.annotation.IdType;
import com.baomidou.mybatisplus.annotation.TableId;
import com.baomidou.mybatisplus.annotation.TableName;
import lombok.Data;

import java.time.LocalDateTime;

/** 用户实体，对应 users 表 */
@Data
@TableName("users")
public class User {

    @TableId(type = IdType.AUTO)
    private Long id;

    private String username;

    private String password;

    private String nickname;

    private LocalDateTime createTime;
}
```

`user-service/src/main/java/com/example/user/mapper/UserMapper.java`：
```java
package com.example.user.mapper;

import com.baomidou.mybatisplus.core.mapper.BaseMapper;
import com.example.user.entity.User;
import org.apache.ibatis.annotations.Mapper;

@Mapper
public interface UserMapper extends BaseMapper<User> {
}
```

`user-service/src/main/java/com/example/user/service/UserService.java`：
```java
package com.example.user.service;

import com.example.user.entity.User;
import com.example.user.mapper.UserMapper;
import lombok.RequiredArgsConstructor;
import org.springframework.stereotype.Service;

@Service
@RequiredArgsConstructor
public class UserService {

    private final UserMapper userMapper;

    public User get(Long id) {
        return userMapper.selectById(id);
    }
}
```

`user-service/src/main/java/com/example/user/controller/UserController.java`：
```java
package com.example.user.controller;

import com.example.user.entity.User;
import com.example.user.service.UserService;
import lombok.RequiredArgsConstructor;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

@RestController
@RequestMapping("/users")
@RequiredArgsConstructor
public class UserController {

    private final UserService userService;

    @GetMapping("/{id}")
    public ResponseEntity<User> get(@PathVariable Long id) {
        User user = userService.get(id);
        if (user == null) {
            return ResponseEntity.notFound().build();
        }
        return ResponseEntity.ok(user);
    }
}
```

`user-service/Dockerfile`：
```dockerfile
FROM maven:3.9-eclipse-temurin-21 AS build
WORKDIR /app
COPY pom.xml .
RUN mvn -q -B dependency:go-offline
COPY src ./src
RUN mvn -q -B package -DskipTests

FROM eclipse-temurin:21-jre
WORKDIR /app
COPY --from=build /app/target/user-service-0.0.1-SNAPSHOT.jar app.jar
EXPOSE 8082
ENTRYPOINT ["java", "-jar", "app.jar"]
```

- [ ] **Step 4: compose 追加并启动验证**

```yaml
  user-service:
    build: ./user-service
    image: microservices/user-service:latest
    container_name: user-service
    environment:
      MYSQL_ROOT_PASSWORD: ${MYSQL_ROOT_PASSWORD}
    ports:
      - "8082:8082"
    depends_on:
      nacos:
        condition: service_healthy
      mysql-order:
        condition: service_healthy
    healthcheck:
      test: ["CMD-SHELL", "bash -c 'exec 3<>/dev/tcp/127.0.0.1/8082' || exit 1"]
      interval: 15s
      timeout: 5s
      retries: 15
      start_period: 60s
    networks: [microservices-net]
```

Run:
```bash
docker compose up -d --build user-service
curl -s http://localhost:8082/users/1
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:8082/users/999
```
Expected: `/users/1` 返回种子用户（username=zhangsan）；`/users/999` 404；Nacos 服务列表出现 `user-service`。

- [ ] **Step 5: Commit**

```bash
git add user-service/ docker-compose.yml
git commit -m "feat: user-service 用户查询服务

Co-Authored-By: Claude <noreply@anthropic.com>"
```

## Task 8: order-service Feign 调用 + Resilience4j 熔断

**Files:**
- Create: `order-service/src/main/java/com/example/order/client/UserClient.java`、`order-service/src/main/java/com/example/order/client/UserClientFallbackFactory.java`、`order-service/src/main/java/com/example/order/dto/UserDto.java`、`order-service/src/test/java/com/example/order/client/UserClientFallbackFactoryTest.java`、`order-service/src/test/java/com/example/order/controller/OrderControllerUserTest.java`
- Modify: `order-service/pom.xml`（+openfeign/+loadbalancer/+circuitbreaker-resilience4j）、`order-service/src/main/resources/application.yml`（feign 熔断开关 + resilience4j 配置）、`order-service/src/main/java/com/example/order/controller/OrderController.java`（+/orders/{id}/user）

**Interfaces:**
- Consumes: Task 7 的 user-service（`GET /users/{id}`）
- Produces: `GET /orders/{id}/user` → 200 {orderId, user} / 200 兜底 {orderId, message:"用户信息暂不可用"}；熔断实例名 `user-service`

- [ ] **Step 1: 写失败测试**

`order-service/src/test/java/com/example/order/client/UserClientFallbackFactoryTest.java`：
```java
package com.example.order.client;

import org.junit.jupiter.api.Test;

import static org.assertj.core.api.Assertions.assertThat;

class UserClientFallbackFactoryTest {

    @Test
    void fallbackReturnsNullUser() {
        UserClient fallback = new UserClientFallbackFactory()
                .create(new RuntimeException("user-service down"));

        assertThat(fallback.getUser(1L)).isNull();
    }
}
```

`order-service/src/test/java/com/example/order/controller/OrderControllerUserTest.java`：
```java
package com.example.order.controller;

import com.example.order.client.UserClient;
import com.example.order.dto.UserDto;
import com.example.order.entity.Order;
import com.example.order.service.OrderService;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.InjectMocks;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;
import org.springframework.cache.CacheManager;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;

import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.when;

@ExtendWith(MockitoExtension.class)
class OrderControllerUserTest {

    @Mock
    private OrderService orderService;

    @Mock
    private CacheManager cacheManager;

    @Mock
    private UserClient userClient;

    @InjectMocks
    private OrderController controller;

    @Test
    void userUnavailableReturnsFallbackMessage() {
        Order order = new Order();
        order.setId(1L);
        order.setUserId(10L);
        when(orderService.get(1L)).thenReturn(order);
        when(userClient.getUser(10L)).thenReturn(null);

        ResponseEntity<Map<String, Object>> response = controller.getUser(1L);

        assertThat(response.getStatusCode()).isEqualTo(HttpStatus.OK);
        assertThat(response.getBody()).containsEntry("orderId", 1L);
        assertThat(response.getBody()).containsEntry("message", "用户信息暂不可用");
    }

    @Test
    void userAvailableReturnsUserInfo() {
        Order order = new Order();
        order.setId(1L);
        order.setUserId(10L);
        when(orderService.get(1L)).thenReturn(order);
        when(userClient.getUser(10L)).thenReturn(new UserDto(10L, "zhangsan", "张三"));

        ResponseEntity<Map<String, Object>> response = controller.getUser(1L);

        assertThat(response.getBody()).containsEntry("orderId", 1L);
        @SuppressWarnings("unchecked")
        Map<String, Object> user = (Map<String, Object>) response.getBody().get("user");
        assertThat(user).containsEntry("username", "zhangsan");
    }
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `cd order-service && docker run --rm -v "$PWD":/app -w /app maven:3.9-eclipse-temurin-21 mvn -q test`
Expected: 编译失败（UserClient/UserDto/controller.getUser 不存在）。

- [ ] **Step 3: 加依赖与配置**

`order-service/pom.xml` 追加依赖（放在 nacos-config 依赖之后）：
```xml
    <dependency>
      <groupId>org.springframework.cloud</groupId>
      <artifactId>spring-cloud-starter-openfeign</artifactId>
    </dependency>
    <dependency>
      <groupId>org.springframework.cloud</groupId>
      <artifactId>spring-cloud-starter-loadbalancer</artifactId>
    </dependency>
    <dependency>
      <groupId>org.springframework.cloud</groupId>
      <artifactId>spring-cloud-starter-circuitbreaker-resilience4j</artifactId>
    </dependency>
```

`application.yml` 追加：
```yaml
spring:
  cloud:
    openfeign:
      circuitbreaker:
        enabled: true

resilience4j:
  circuitbreaker:
    instances:
      user-service:            # Feign client 名
        sliding-window-size: 10
        failure-rate-threshold: 50
        wait-duration-in-open-state: 30s
```

`OrderServiceApplication` 加 `@EnableFeignClients`：
```java
@SpringBootApplication
@EnableFeignClients
public class OrderServiceApplication {
```

- [ ] **Step 4: 实现 Feign 客户端与兜底**

`order-service/src/main/java/com/example/order/dto/UserDto.java`：
```java
package com.example.order.dto;

/** user-service 返回的用户信息投影 */
public record UserDto(Long id, String username, String nickname) {
}
```

`order-service/src/main/java/com/example/order/client/UserClient.java`：
```java
package com.example.order.client;

import com.example.order.dto.UserDto;
import org.springframework.cloud.openfeign.FeignClient;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;

/** 调用 user-service（经 Nacos 发现），熔断兜底见 UserClientFallbackFactory */
@FeignClient(name = "user-service", path = "/users", fallbackFactory = UserClientFallbackFactory.class)
public interface UserClient {

    @GetMapping("/{id}")
    UserDto getUser(@PathVariable("id") Long id);
}
```

`order-service/src/main/java/com/example/order/client/UserClientFallbackFactory.java`：
```java
package com.example.order.client;

import lombok.extern.slf4j.Slf4j;
import org.springframework.cloud.openfeign.FallbackFactory;
import org.springframework.stereotype.Component;

/** user-service 不可用/熔断时返回 null，由 Controller 转成兜底响应 */
@Slf4j
@Component
public class UserClientFallbackFactory implements FallbackFactory<UserClient> {

    @Override
    public UserClient create(Throwable cause) {
        log.warn("user-service 调用降级: {}", cause.getMessage());
        return id -> null;
    }
}
```

- [ ] **Step 5: Controller 加 /orders/{id}/user**

`OrderController` 追加（注入 `UserClient`）：
```java
    private final UserClient userClient;

    /** 订单 + 下单用户信息（Feign 调 user-service，失败走兜底） */
    @GetMapping("/{id}/user")
    public ResponseEntity<Map<String, Object>> getUser(@PathVariable Long id) {
        Order order = orderService.get(id);
        if (order == null) {
            return ResponseEntity.notFound().build();
        }
        UserDto user = userClient.getUser(order.getUserId());
        if (user == null) {
            return ResponseEntity.ok(Map.of(
                    "orderId", id,
                    "message", "用户信息暂不可用"));
        }
        return ResponseEntity.ok(Map.of(
                "orderId", id,
                "user", user));
    }
```
补充 import：
```java
import com.example.order.client.UserClient;
import com.example.order.dto.UserDto;
import java.util.Map;
```

- [ ] **Step 6: 运行测试确认通过**

Run: `cd order-service && docker run --rm -v "$PWD":/app -w /app maven:3.9-eclipse-temurin-21 mvn -q test`
Expected: 全部 PASS。

- [ ] **Step 7: 重建并验证熔断场景**

Run:
```bash
docker compose up -d --build order-service
ID=$(curl -s -X POST http://localhost:8081/orders -H 'Content-Type: application/json' \
  -d '{"userId":1,"productName":"耳机","amount":299.00}' | sed 's/.*"id":\([0-9]*\).*/\1/')
echo "== 正常调用（应返回用户信息）=="
curl -s http://localhost:8081/orders/$ID/user; echo
echo "== 停掉 user-service =="
docker stop user-service
echo "== 熔断场景（应返回兜底，不报 500）=="
curl -s http://localhost:8081/orders/$ID/user; echo
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:8081/orders/$ID/user
echo "== 恢复 user-service =="
docker start user-service
sleep 40
curl -s http://localhost:8081/orders/$ID/user; echo
```
Expected: 正常时返回 user 信息；停掉后返回 `{"orderId":...,"message":"用户信息暂不可用"}` 且 HTTP 200（不抛 500），日志出现 "user-service 调用降级"；恢复并等待 40s（open-state 30s）后再次正常返回。

- [ ] **Step 8: Commit**

```bash
git add order-service/
git commit -m "feat: Feign 服务间调用 + Resilience4j 熔断降级

Co-Authored-By: Claude <noreply@anthropic.com>"
```

## Task 9: 服务级限流（@RateLimiter）+ 熔断观测（Actuator）

**Files:**
- Modify: `order-service/src/main/java/com/example/order/controller/OrderController.java`（@RateLimiter + 429 异常处理）、`order-service/src/main/resources/application.yml`（ratelimiter 配置 + actuator 暴露）

**Interfaces:**
- Consumes: Task 8 产物
- Produces: `GET /orders/{id}` 服务级限流（5 次/秒，超限 429）；`/actuator/health` 显示 circuitBreakers 状态；`/actuator/circuitbreakers`、`/actuator/circuitbreakerevents` 可查熔断状态与事件

- [ ] **Step 1: 加配置**

`application.yml` 的 resilience4j 追加：
```yaml
  ratelimiter:
    instances:
      getOrder:
        limit-for-period: 5
        limit-refresh-period: 1s
        timeout-duration: 0
```
management 修改为：
```yaml
management:
  endpoints:
    web:
      exposure:
        include: health,info,circuitbreakers,circuitbreakerevents
  health:
    circuitbreakers:
      enabled: true
```

- [ ] **Step 2: Controller 加 @RateLimiter 与 429 处理**

`OrderController` 的 get 方法加注解：
```java
    @GetMapping("/{id}")
    @RateLimiter(name = "getOrder", fallbackMethod = "rateLimitFallback")
    public ResponseEntity<Order> get(@PathVariable Long id) {
```
追加兜底方法（注意：fallback 方法必须接收与主方法相同的参数并抛出 RequestNotPermitted 让全局处理转 429，或直接返回 429）：
```java
    /** 服务级限流兜底：返回 429 */
    public ResponseEntity<Order> rateLimitFallback(Long id, Throwable t) {
        return ResponseEntity.status(HttpStatus.TOO_MANY_REQUESTS).build();
    }
```
补充 import：
```java
import io.github.resilience4j.ratelimiter.annotation.RateLimiter;
```

（注：本任务无新增单元测试——@RateLimiter 依赖 Aspect 与 Spring 上下文，纯单元测试覆盖不到；行为由 Step 3 的 curl 验收覆盖。）

- [ ] **Step 3: 重建并验证限流与观测**

Run:
```bash
docker compose up -d --build order-service
ID=$(curl -s -X POST http://localhost:8081/orders -H 'Content-Type: application/json' \
  -d '{"userId":1,"productName":"音箱","amount":199.00}' | sed 's/.*"id":\([0-9]*\).*/\1/')
echo "== 服务级限流（5/s，快速 10 连发应出现 429）=="
for i in $(seq 1 10); do curl -s -o /dev/null -w "%{http_code} " http://localhost:8081/orders/$ID; done; echo
echo "== 熔断观测 =="
curl -s http://localhost:8081/actuator/health; echo
curl -s http://localhost:8081/actuator/circuitbreakers; echo
```
Expected: 10 连发中部分 429（前 5 个 200，后 5 个 429 或类似分布）；health 含 `"circuitBreakers":{"status":"UP","details":{"user-service":{"status":"CLOSED"}}}`；circuitbreakers 端点显示 user-service 实例状态。

- [ ] **Step 4: Commit**

```bash
git add order-service/
git commit -m "feat: Resilience4j 服务级限流 + Actuator 熔断观测

Co-Authored-By: Claude <noreply@anthropic.com>"
```

## Task 10: nginx 边缘层

**Files:**
- Create: `nginx/nginx.conf`
- Modify: `docker-compose.yml`（追加 nginx 服务）

**Interfaces:**
- Consumes: gateway(8080)
- Produces: `http://localhost/` 与 `http://localhost/api/order/**` 全链路转发

- [ ] **Step 1: 写 nginx.conf**

`nginx/nginx.conf`：
```nginx
worker_processes auto;

events {
    worker_connections 1024;
}

http {
    upstream gateway_upstream {
        server gateway:8080;
    }

    server {
        listen 80;

        location / {
            proxy_pass http://gateway_upstream;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        }
    }
}
```

- [ ] **Step 2: compose 追加 nginx 并启动**

```yaml
  nginx:
    image: nginx:1.27-alpine
    container_name: nginx
    ports:
      - "80:80"
    volumes:
      - ./nginx/nginx.conf:/etc/nginx/nginx.conf:ro
    depends_on:
      gateway:
        condition: service_healthy
    healthcheck:
      test: ["CMD", "wget", "-q", "-O", "/dev/null", "http://localhost/actuator/health"]
      interval: 15s
      timeout: 5s
      retries: 10
    networks: [microservices-net]
```

Run:
```bash
docker compose up -d nginx
docker compose ps
```

- [ ] **Step 3: 全链路验证**

Run:
```bash
curl -s http://localhost/actuator/health; echo
curl -s http://localhost/api/order/orders?page=1&size=3
```
Expected: `localhost:80` 经 nginx→gateway→order-service 全链路 200。（若 502，`docker logs nginx` 查 upstream 解析。）

- [ ] **Step 4: Commit**

```bash
git add nginx/ docker-compose.yml
git commit -m "feat: nginx 边缘层接入

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

# 阶段 3：安全与异步（+2 容器，共 10）

## Task 11: auth-service（登录 + JWT 签发）

**Files:**
- Create: `auth-service/pom.xml`、`auth-service/Dockerfile`、`auth-service/src/main/resources/application.yml`、`auth-service/src/main/java/com/example/auth/AuthServiceApplication.java`、`auth-service/src/main/java/com/example/auth/entity/User.java`、`auth-service/src/main/java/com/example/auth/mapper/UserMapper.java`、`auth-service/src/main/java/com/example/auth/service/JwtService.java`、`auth-service/src/main/java/com/example/auth/service/AuthService.java`、`auth-service/src/main/java/com/example/auth/controller/AuthController.java`、`auth-service/src/main/java/com/example/auth/dto/LoginRequest.java`、`auth-service/src/main/java/com/example/auth/config/PasswordConfig.java`、`auth-service/src/test/java/com/example/auth/service/JwtServiceTest.java`、`auth-service/src/test/java/com/example/auth/service/AuthServiceTest.java`
- Modify: `docker-compose.yml`（追加 auth-service）

**Interfaces:**
- Consumes: mysql-order 的 users 表；Nacos 配置 `auth-service.yaml` 的 `auth.jwt.secret`
- Produces: `POST /api/auth/login` {username,password} → 200 {token} / 401；JWT 为 HS256、claims 含 `sub`(username)/`uid`、有效期 2h

- [ ] **Step 1: 写失败测试**

`auth-service/src/test/java/com/example/auth/service/JwtServiceTest.java`：
```java
package com.example.auth.service;

import io.jsonwebtoken.Claims;
import io.jsonwebtoken.JwtException;
import io.jsonwebtoken.Jwts;
import io.jsonwebtoken.security.Keys;
import org.junit.jupiter.api.Test;

import javax.crypto.SecretKey;
import java.nio.charset.StandardCharsets;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class JwtServiceTest {

    private static final String SECRET = "0123456789abcdef0123456789abcdef0123456789abcdef";

    @Test
    void generateAndParseRoundTrip() {
        JwtService jwtService = new JwtService(SECRET);
        String token = jwtService.generate("zhangsan", 1L);

        Claims claims = Jwts.parser().verifyWith(key(SECRET)).build()
                .parseSignedClaims(token).getPayload();

        assertThat(claims.getSubject()).isEqualTo("zhangsan");
        assertThat(claims.get("uid", Long.class)).isEqualTo(1L);
    }

    @Test
    void tokenSignedWithWrongSecretIsRejected() {
        JwtService jwtService = new JwtService(SECRET);
        String token = jwtService.generate("zhangsan", 1L);

        // 错误密钥也要 ≥32 字符，否则抛的是 WeakKeyException 而不是签名校验失败
        assertThatThrownBy(() -> Jwts.parser()
                .verifyWith(key("wrong-secret-0123456789abcdef0123456789abcdef")).build()
                .parseSignedClaims(token))
                .isInstanceOf(JwtException.class);
    }

    private static SecretKey key(String secret) {
        return Keys.hmacShaKeyFor(secret.getBytes(StandardCharsets.UTF_8));
    }
}
```

`auth-service/src/test/java/com/example/auth/service/AuthServiceTest.java`：
```java
package com.example.auth.service;

import com.baomidou.mybatisplus.core.conditions.query.LambdaQueryWrapper;
import com.example.auth.entity.User;
import com.example.auth.mapper.UserMapper;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;
import org.springframework.security.crypto.bcrypt.BCryptPasswordEncoder;
import org.springframework.security.crypto.password.PasswordEncoder;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.when;

@ExtendWith(MockitoExtension.class)
class AuthServiceTest {

    @Mock
    private UserMapper userMapper;

    private final PasswordEncoder encoder = new BCryptPasswordEncoder();
    private final JwtService jwtService = new JwtService("0123456789abcdef0123456789abcdef0123456789abcdef");

    private AuthService authService;

    @BeforeEach
    void setUp() {
        // 手动组装：@InjectMocks 只会注入 @Mock 字段，encoder/jwtService 是真实实例
        authService = new AuthService(userMapper, encoder, jwtService);
    }

    @Test
    void correctPasswordReturnsToken() {
        User user = new User();
        user.setId(1L);
        user.setUsername("zhangsan");
        user.setPassword(encoder.encode("123456"));
        when(userMapper.selectOne(any(LambdaQueryWrapper.class))).thenReturn(user);

        String token = authService.login("zhangsan", "123456");

        assertThat(token).isNotBlank();
    }

    @Test
    void wrongPasswordThrows() {
        User user = new User();
        user.setId(1L);
        user.setUsername("zhangsan");
        user.setPassword(encoder.encode("123456"));
        when(userMapper.selectOne(any(LambdaQueryWrapper.class))).thenReturn(user);

        assertThatThrownBy(() -> authService.login("zhangsan", "wrong"))
                .isInstanceOf(BadCredentialsException.class);
    }

    @Test
    void unknownUserThrows() {
        when(userMapper.selectOne(any(LambdaQueryWrapper.class))).thenReturn(null);

        assertThatThrownBy(() -> authService.login("nobody", "123456"))
                .isInstanceOf(BadCredentialsException.class);
    }
}
```
（`BadCredentialsException` 在 Step 4 中定义。）

- [ ] **Step 2: 运行测试确认失败**

Run: `cd auth-service && docker run --rm -v "$PWD":/app -w /app maven:3.9-eclipse-temurin-21 mvn -q test`
Expected: 编译失败。

- [ ] **Step 3: 写工程文件**

`auth-service/pom.xml`（与 user-service 差异：artifactId/name 为 auth-service，多 nacos-config/security-crypto/jjwt 依赖）：
```xml
<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0"
         xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
         xsi:schemaLocation="http://maven.apache.org/POM/4.0.0 https://maven.apache.org/xsd/maven-4.0.0.xsd">
  <modelVersion>4.0.0</modelVersion>
  <parent>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-starter-parent</artifactId>
    <version>3.5.4</version>
    <relativePath/>
  </parent>

  <groupId>com.example</groupId>
  <artifactId>auth-service</artifactId>
  <version>0.0.1-SNAPSHOT</version>
  <name>auth-service</name>

  <properties>
    <java.version>21</java.version>
    <spring-cloud.version>2025.0.0</spring-cloud.version>
    <spring-cloud-alibaba.version>2025.0.0.0</spring-cloud-alibaba.version>
    <mybatis-plus.version>3.5.12</mybatis-plus.version>
    <jjwt.version>0.12.6</jjwt.version>
  </properties>

  <dependencyManagement>
    <dependencies>
      <dependency>
        <groupId>org.springframework.cloud</groupId>
        <artifactId>spring-cloud-dependencies</artifactId>
        <version>${spring-cloud.version}</version>
        <type>pom</type>
        <scope>import</scope>
      </dependency>
      <dependency>
        <groupId>com.alibaba.cloud</groupId>
        <artifactId>spring-cloud-alibaba-dependencies</artifactId>
        <version>${spring-cloud-alibaba.version}</version>
        <type>pom</type>
        <scope>import</scope>
      </dependency>
      <dependency>
        <groupId>com.baomidou</groupId>
        <artifactId>mybatis-plus-bom</artifactId>
        <version>${mybatis-plus.version}</version>
        <type>pom</type>
        <scope>import</scope>
      </dependency>
    </dependencies>
  </dependencyManagement>

  <dependencies>
    <dependency>
      <groupId>org.springframework.boot</groupId>
      <artifactId>spring-boot-starter-web</artifactId>
    </dependency>
    <dependency>
      <groupId>org.springframework.boot</groupId>
      <artifactId>spring-boot-starter-actuator</artifactId>
    </dependency>
    <dependency>
      <groupId>com.baomidou</groupId>
      <artifactId>mybatis-plus-spring-boot3-starter</artifactId>
    </dependency>
    <dependency>
      <groupId>com.mysql</groupId>
      <artifactId>mysql-connector-j</artifactId>
      <scope>runtime</scope>
    </dependency>
    <dependency>
      <groupId>com.alibaba.cloud</groupId>
      <artifactId>spring-cloud-starter-alibaba-nacos-discovery</artifactId>
    </dependency>
    <dependency>
      <groupId>com.alibaba.cloud</groupId>
      <artifactId>spring-cloud-starter-alibaba-nacos-config</artifactId>
    </dependency>
    <dependency>
      <groupId>org.springframework.security</groupId>
      <artifactId>spring-security-crypto</artifactId>
    </dependency>
    <dependency>
      <groupId>io.jsonwebtoken</groupId>
      <artifactId>jjwt-api</artifactId>
      <version>${jjwt.version}</version>
    </dependency>
    <dependency>
      <groupId>io.jsonwebtoken</groupId>
      <artifactId>jjwt-impl</artifactId>
      <version>${jjwt.version}</version>
      <scope>runtime</scope>
    </dependency>
    <dependency>
      <groupId>io.jsonwebtoken</groupId>
      <artifactId>jjwt-jackson</artifactId>
      <version>${jjwt.version}</version>
      <scope>runtime</scope>
    </dependency>
    <dependency>
      <groupId>org.projectlombok</groupId>
      <artifactId>lombok</artifactId>
      <optional>true</optional>
    </dependency>
    <dependency>
      <groupId>org.springframework.boot</groupId>
      <artifactId>spring-boot-starter-test</artifactId>
      <scope>test</scope>
    </dependency>
  </dependencies>

  <build>
    <plugins>
      <plugin>
        <groupId>org.springframework.boot</groupId>
        <artifactId>spring-boot-maven-plugin</artifactId>
      </plugin>
    </plugins>
  </build>
</project>
```

`auth-service/src/main/resources/application.yml`：
```yaml
server:
  port: 8083

spring:
  application:
    name: auth-service
  config:
    import: nacos:auth-service.yaml
  cloud:
    nacos:
      server-addr: nacos:8848
      username: nacos
      password: nacos
  datasource:
    driver-class-name: com.mysql.cj.jdbc.Driver
    url: jdbc:mysql://mysql-order:3306/order_db?useUnicode=true&characterEncoding=utf8&serverTimezone=Asia/Shanghai&useSSL=false&allowPublicKeyRetrieval=true
    username: root
    password: ${MYSQL_ROOT_PASSWORD}

mybatis-plus:
  configuration:
    map-underscore-to-camel-case: true

management:
  endpoints:
    web:
      exposure:
        include: health,info

# 本地兜底；Nacos 的 auth-service.yaml 会覆盖
auth:
  jwt:
    secret: local-dev-secret-0123456789abcdef0123456789abcdef
```

`auth-service/src/main/java/com/example/auth/AuthServiceApplication.java`：
```java
package com.example.auth;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;

@SpringBootApplication
public class AuthServiceApplication {

    public static void main(String[] args) {
        SpringApplication.run(AuthServiceApplication.class, args);
    }
}
```

`auth-service/src/main/java/com/example/auth/entity/User.java`：与 user-service 的 User 相同（包名 `com.example.auth.entity`）。

`auth-service/src/main/java/com/example/auth/mapper/UserMapper.java`：与 user-service 相同（包名 `com.example.auth.mapper`）。

`auth-service/src/main/java/com/example/auth/config/PasswordConfig.java`：
```java
package com.example.auth.config;

import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.security.crypto.bcrypt.BCryptPasswordEncoder;
import org.springframework.security.crypto.password.PasswordEncoder;

@Configuration
public class PasswordConfig {

    @Bean
    public PasswordEncoder passwordEncoder() {
        return new BCryptPasswordEncoder();
    }
}
```

`auth-service/src/main/java/com/example/auth/dto/LoginRequest.java`：
```java
package com.example.auth.dto;

/** 登录请求体 */
public record LoginRequest(String username, String password) {
}
```

- [ ] **Step 4: 实现 JwtService / AuthService / BadCredentialsException / Controller**

`auth-service/src/main/java/com/example/auth/service/JwtService.java`：
```java
package com.example.auth.service;

import io.jsonwebtoken.Jwts;
import io.jsonwebtoken.security.Keys;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Service;

import javax.crypto.SecretKey;
import java.nio.charset.StandardCharsets;
import java.util.Date;

/** HS256 JWT 签发（密钥来自 Nacos 配置 auth.jwt.secret） */
@Service
public class JwtService {

    private final SecretKey key;

    public JwtService(@Value("${auth.jwt.secret}") String secret) {
        this.key = Keys.hmacShaKeyFor(secret.getBytes(StandardCharsets.UTF_8));
    }

    /** 签发 2 小时有效的 token，sub=username，uid=userId */
    public String generate(String username, Long userId) {
        return Jwts.builder()
                .subject(username)
                .claim("uid", userId)
                .issuedAt(new Date())
                .expiration(new Date(System.currentTimeMillis() + 2 * 3600_000L))
                .signWith(key)
                .compact();
    }
}
```

`auth-service/src/main/java/com/example/auth/service/BadCredentialsException.java`：
```java
package com.example.auth.service;

/** 用户名或密码错误 */
public class BadCredentialsException extends RuntimeException {

    public BadCredentialsException(String message) {
        super(message);
    }
}
```

`auth-service/src/main/java/com/example/auth/service/AuthService.java`：
```java
package com.example.auth.service;

import com.baomidou.mybatisplus.core.conditions.query.LambdaQueryWrapper;
import com.example.auth.entity.User;
import com.example.auth.mapper.UserMapper;
import lombok.RequiredArgsConstructor;
import org.springframework.security.crypto.password.PasswordEncoder;
import org.springframework.stereotype.Service;

@Service
@RequiredArgsConstructor
public class AuthService {

    private final UserMapper userMapper;
    private final PasswordEncoder passwordEncoder;
    private final JwtService jwtService;

    /** 校验用户名密码，成功返回 JWT */
    public String login(String username, String password) {
        User user = userMapper.selectOne(
                new LambdaQueryWrapper<User>().eq(User::getUsername, username));
        if (user == null || !passwordEncoder.matches(password, user.getPassword())) {
            throw new BadCredentialsException("用户名或密码错误");
        }
        return jwtService.generate(user.getUsername(), user.getId());
    }
}
```

`auth-service/src/main/java/com/example/auth/controller/AuthController.java`：
```java
package com.example.auth.controller;

import com.example.auth.dto.LoginRequest;
import com.example.auth.service.AuthService;
import com.example.auth.service.BadCredentialsException;
import lombok.RequiredArgsConstructor;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;

import java.util.Map;

@RestController
@RequestMapping("/api/auth")
@RequiredArgsConstructor
public class AuthController {

    private final AuthService authService;

    @PostMapping("/login")
    public ResponseEntity<Map<String, String>> login(@RequestBody LoginRequest request) {
        try {
            String token = authService.login(request.username(), request.password());
            return ResponseEntity.ok(Map.of("token", token));
        } catch (BadCredentialsException e) {
            return ResponseEntity.status(HttpStatus.UNAUTHORIZED)
                    .body(Map.of("message", e.getMessage()));
        }
    }
}
```

`auth-service/Dockerfile`：
```dockerfile
FROM maven:3.9-eclipse-temurin-21 AS build
WORKDIR /app
COPY pom.xml .
RUN mvn -q -B dependency:go-offline
COPY src ./src
RUN mvn -q -B package -DskipTests

FROM eclipse-temurin:21-jre
WORKDIR /app
COPY --from=build /app/target/auth-service-0.0.1-SNAPSHOT.jar app.jar
EXPOSE 8083
ENTRYPOINT ["java", "-jar", "app.jar"]
```

- [ ] **Step 5: 发布 Nacos 配置 auth-service.yaml**

Run（JWT 密钥用 openssl 生成，与 Task 12 gateway 共用同一值）：
```bash
JWT_SECRET=$(openssl rand -hex 32)
echo "生成的 JWT 密钥（记住它，Task 12 要再用一次）: $JWT_SECRET"
TOKEN=$(curl -s -X POST 'http://localhost:8848/nacos/v3/auth/user/login' -d 'username=nacos&password=nacos' | sed 's/.*"accessToken":"\([^"]*\)".*/\1/')
curl -s -X POST 'http://localhost:8848/nacos/v3/admin/cs/config' -H "accessToken: $TOKEN" \
  --data-urlencode 'dataId=auth-service.yaml' --data-urlencode 'groupName=DEFAULT_GROUP' \
  --data-urlencode "content=auth:
  jwt:
    secret: $JWT_SECRET"
```
Expected: 返回 `{"code":0,...,"data":true}`。（Nacos 3.x 实测：管理 API 在 8848 端口 `/nacos/v3/...` 前缀下；18080 控制台端口只承载 UI 与 readiness，其上的管理 API 会 404。）

- [ ] **Step 6: compose 追加 auth-service 并启动验证**

```yaml
  auth-service:
    build: ./auth-service
    image: microservices/auth-service:latest
    container_name: auth-service
    environment:
      MYSQL_ROOT_PASSWORD: ${MYSQL_ROOT_PASSWORD}
    ports:
      - "8083:8083"
    depends_on:
      nacos:
        condition: service_healthy
      mysql-order:
        condition: service_healthy
    healthcheck:
      test: ["CMD-SHELL", "bash -c 'exec 3<>/dev/tcp/127.0.0.1/8083' || exit 1"]
      interval: 15s
      timeout: 5s
      retries: 15
      start_period: 60s
    networks: [microservices-net]
```

Run:
```bash
docker compose up -d --build auth-service
curl -s -X POST http://localhost:8083/api/auth/login -H 'Content-Type: application/json' \
  -d '{"username":"zhangsan","password":"123456"}'
curl -s -o /dev/null -w "%{http_code}\n" -X POST http://localhost:8083/api/auth/login \
  -H 'Content-Type: application/json' -d '{"username":"zhangsan","password":"wrong"}'
```
Expected: 正确密码返回 `{"token":"eyJ..."}`；错误密码 401。（若 401 且密码正确——种子数据 BCrypt 密文与本机生成不一致，先 `docker exec mysql-order mysql -uroot -proot123456 -e "SELECT * FROM order_db.users;"` 核对，再用下面命令重新生成 "123456" 的密文、回填 `sql/order_db.sql` 的 INSERT 语句，然后 `docker compose down -v && docker compose up -d` 重建：

```bash
docker run --rm python:3.12-alpine sh -c 'pip install bcrypt -q && python -c "import bcrypt; print(bcrypt.hashpw(b\"123456\", bcrypt.gensalt()).decode())"'
```

）

- [ ] **Step 7: Commit**

```bash
git add auth-service/ docker-compose.yml
git commit -m "feat: auth-service 登录与 JWT 签发

Co-Authored-By: Claude <noreply@anthropic.com>"
```

## Task 12: gateway JWT 全局过滤器

**Files:**
- Create: `gateway/src/main/java/com/example/gateway/filter/JwtAuthFilter.java`、`gateway/src/test/java/com/example/gateway/filter/JwtAuthFilterTest.java`
- Modify: `gateway/pom.xml`（+jjwt 依赖）

**Interfaces:**
- Consumes: Task 11 的 auth-service 与 JWT 格式（HS256、sub/uid claims）；Nacos `gateway.yaml` 的 `auth.jwt.secret`（与 auth-service.yaml 同值）
- Produces: 网关全局校验——白名单 `/api/auth/login`、`/actuator/health` 放行；其余请求无/错 token → 401

- [ ] **Step 1: 写失败测试**

`gateway/src/test/java/com/example/gateway/filter/JwtAuthFilterTest.java`：
```java
package com.example.gateway.filter;

import io.jsonwebtoken.Jwts;
import io.jsonwebtoken.security.Keys;
import org.junit.jupiter.api.Test;
import org.springframework.cloud.gateway.filter.GatewayFilterChain;
import org.springframework.http.HttpStatus;
import org.springframework.mock.http.server.reactive.MockServerHttpRequest;
import org.springframework.mock.web.server.MockServerWebExchange;
import reactor.core.publisher.Mono;

import javax.crypto.SecretKey;
import java.nio.charset.StandardCharsets;
import java.util.Date;
import java.util.concurrent.atomic.AtomicBoolean;

import static org.assertj.core.api.Assertions.assertThat;

class JwtAuthFilterTest {

    private static final String SECRET = "0123456789abcdef0123456789abcdef0123456789abcdef";

    private final JwtAuthFilter filter = new JwtAuthFilter(SECRET);

    @Test
    void whitelistLoginPathPassesWithoutToken() {
        AtomicBoolean called = new AtomicBoolean(false);
        MockServerWebExchange exchange = MockServerWebExchange.from(
                MockServerHttpRequest.post("/api/auth/login").build());

        filter.filter(exchange, chain(called)).block();

        assertThat(called).isTrue();
    }

    @Test
    void missingTokenReturns401() {
        AtomicBoolean called = new AtomicBoolean(false);
        MockServerWebExchange exchange = MockServerWebExchange.from(
                MockServerHttpRequest.get("/api/order/orders").build());

        filter.filter(exchange, chain(called)).block();

        assertThat(exchange.getResponse().getStatusCode()).isEqualTo(HttpStatus.UNAUTHORIZED);
        assertThat(called).isFalse();
    }

    @Test
    void validTokenPasses() {
        AtomicBoolean called = new AtomicBoolean(false);
        MockServerWebExchange exchange = MockServerWebExchange.from(
                MockServerHttpRequest.get("/api/order/orders")
                        .header("Authorization", "Bearer " + token(SECRET)).build());

        filter.filter(exchange, chain(called)).block();

        assertThat(called).isTrue();
    }

    @Test
    void tokenSignedWithWrongSecretReturns401() {
        AtomicBoolean called = new AtomicBoolean(false);
        MockServerWebExchange exchange = MockServerWebExchange.from(
                MockServerHttpRequest.get("/api/order/orders")
                        .header("Authorization", "Bearer "
                                + token("wrong-secret-wrong-secret-wrong-secret-32c")).build());

        filter.filter(exchange, chain(called)).block();

        assertThat(exchange.getResponse().getStatusCode()).isEqualTo(HttpStatus.UNAUTHORIZED);
        assertThat(called).isFalse();
    }

    private static String token(String secret) {
        SecretKey key = Keys.hmacShaKeyFor(secret.getBytes(StandardCharsets.UTF_8));
        return Jwts.builder().subject("zhangsan").claim("uid", 1L)
                .issuedAt(new Date()).expiration(new Date(System.currentTimeMillis() + 3600_000L))
                .signWith(key).compact();
    }

    private static GatewayFilterChain chain(AtomicBoolean called) {
        return exchange -> {
            called.set(true);
            return Mono.empty();
        };
    }
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `cd gateway && docker run --rm -v "$PWD":/app -w /app maven:3.9-eclipse-temurin-21 mvn -q test`
Expected: 编译失败（JwtAuthFilter 不存在）。

- [ ] **Step 3: 加 jjwt 依赖**

`gateway/pom.xml` 追加（与 auth-service 相同的三件套 jjwt-api/impl/jackson 0.12.6）。

- [ ] **Step 4: 实现过滤器**

`gateway/src/main/java/com/example/gateway/filter/JwtAuthFilter.java`：
```java
package com.example.gateway.filter;

import io.jsonwebtoken.JwtException;
import io.jsonwebtoken.Jwts;
import io.jsonwebtoken.security.Keys;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.cloud.gateway.filter.GatewayFilterChain;
import org.springframework.cloud.gateway.filter.GlobalFilter;
import org.springframework.core.Ordered;
import org.springframework.http.HttpHeaders;
import org.springframework.http.HttpStatus;
import org.springframework.http.server.reactive.ServerHttpRequest;
import org.springframework.stereotype.Component;
import org.springframework.web.server.ServerWebExchange;
import reactor.core.publisher.Mono;

import javax.crypto.SecretKey;
import java.nio.charset.StandardCharsets;
import java.util.List;

/** 网关全局 JWT 校验：白名单放行，其余请求校验 Bearer token */
@Component
public class JwtAuthFilter implements GlobalFilter, Ordered {

    /** 无需认证的路径 */
    private static final List<String> WHITELIST = List.of("/api/auth/login", "/actuator/health");

    private final SecretKey key;

    public JwtAuthFilter(@Value("${auth.jwt.secret}") String secret) {
        this.key = Keys.hmacShaKeyFor(secret.getBytes(StandardCharsets.UTF_8));
    }

    @Override
    public Mono<Void> filter(ServerWebExchange exchange, GatewayFilterChain chain) {
        String path = exchange.getRequest().getURI().getPath();
        if (WHITELIST.contains(path)) {
            return chain.filter(exchange);
        }
        String authorization = exchange.getRequest().getHeaders().getFirst(HttpHeaders.AUTHORIZATION);
        if (authorization == null || !authorization.startsWith("Bearer ")) {
            return unauthorized(exchange);
        }
        try {
            Jwts.parser().verifyWith(key).build()
                    .parseSignedClaims(authorization.substring(7));
            return chain.filter(exchange);
        } catch (JwtException | IllegalArgumentException e) {
            return unauthorized(exchange);
        }
    }

    private Mono<Void> unauthorized(ServerWebExchange exchange) {
        exchange.getResponse().setStatusCode(HttpStatus.UNAUTHORIZED);
        return exchange.getResponse().setComplete();
    }

    @Override
    public int getOrder() {
        return -100;
    }
}
```

- [ ] **Step 5: 发布 gateway.yaml（含与 auth-service 相同的 JWT 密钥）+ 网关加 auth 路由**

`gateway/src/main/resources/application.yml` 的 `spring.cloud.gateway.routes` 追加一条（auth-service 控制器映射的就是 `/api/auth`，**不加** StripPrefix）：
```yaml
        - id: auth-service
          uri: lb://auth-service
          predicates:
            - Path=/api/auth/**
```

Run（`$JWT_SECRET` 用 Task 11 Step 5 生成的同一个值）：
```bash
TOKEN=$(curl -s -X POST 'http://localhost:8848/nacos/v3/auth/user/login' -d 'username=nacos&password=nacos' | sed 's/.*"accessToken":"\([^"]*\)".*/\1/')
curl -s -X POST 'http://localhost:8848/nacos/v3/admin/cs/config' -H "accessToken: $TOKEN" \
  --data-urlencode 'dataId=gateway.yaml' --data-urlencode 'groupName=DEFAULT_GROUP' \
  --data-urlencode "content=logging:
  level:
    org.springframework.cloud.gateway: INFO
auth:
  jwt:
    secret: $JWT_SECRET"
```
Expected: 返回 `true`。

- [ ] **Step 6: 运行测试确认通过**

Run: `cd gateway && docker run --rm -v "$PWD":/app -w /app maven:3.9-eclipse-temurin-21 mvn -q test`
Expected: 4 个测试全 PASS。

- [ ] **Step 7: 重建并全链路验证认证**

Run:
```bash
docker compose up -d --build gateway
echo "== 无 token（应 401）=="
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:8080/api/order/orders
echo "== 白名单 login（应 200）=="
TOKEN=$(curl -s -X POST http://localhost:8080/api/auth/login -H 'Content-Type: application/json' \
  -d '{"username":"zhangsan","password":"123456"}' | sed 's/.*"token":"\([^"]*\)".*/\1/')
echo "token 前缀: ${TOKEN:0:20}..."
echo "== 带 token（应 200）=="
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:8080/api/order/orders -H "Authorization: Bearer $TOKEN"
echo "== 伪造 token（应 401）=="
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:8080/api/order/orders -H "Authorization: Bearer abc.def.ghi"
```
Expected: 依次 401、200、200、401。

- [ ] **Step 8: Commit**

```bash
git add gateway/
git commit -m "feat: gateway 全局 JWT 校验过滤器

Co-Authored-By: Claude <noreply@anthropic.com>"
```

## Task 13: RabbitMQ 接入（订单消息异步化）

**Files:**
- Create: `order-service/src/main/java/com/example/order/mq/OrderCreatedEvent.java`、`order-service/src/main/java/com/example/order/mq/RabbitConfig.java`、`order-service/src/main/java/com/example/order/mq/OrderMqConsumer.java`、`order-service/src/test/java/com/example/order/mq/OrderMqConsumerTest.java`、`order-service/src/test/java/com/example/order/mq/OrderCreatedEventJsonTest.java`
- Modify: `order-service/pom.xml`（+amqp）、`order-service/src/main/resources/application.yml`（rabbitmq 连接）、`order-service/src/main/java/com/example/order/service/OrderService.java`（创建成功后发消息）、`order-service/src/main/java/com/example/order/mapper/OrderMapper.java`（+updateStatus 方法）、`docker-compose.yml`（追加 rabbitmq）

**Interfaces:**
- Consumes: rabbitmq(5672)；`OrderService.create` 成功路径
- Produces: 交换机 `order.exchange`（direct）、队列 `order.created.queue`（routingKey `order.created`，durable）；消息体 JSON `{"orderId":..,"orderNo":"..","amount":..}`；消费后 `orders.status` 置 1

- [ ] **Step 1: 写失败测试**

`order-service/src/test/java/com/example/order/mq/OrderCreatedEventJsonTest.java`：
```java
package com.example.order.mq;

import org.junit.jupiter.api.Test;
import org.springframework.amqp.support.converter.Jackson2JsonMessageConverter;
import org.springframework.amqp.core.Message;
import org.springframework.amqp.core.MessageProperties;

import java.math.BigDecimal;

import static org.assertj.core.api.Assertions.assertThat;

class OrderCreatedEventJsonTest {

    @Test
    void eventSurvivesJsonRoundTrip() {
        Jackson2JsonMessageConverter converter = new Jackson2JsonMessageConverter();
        OrderCreatedEvent event = new OrderCreatedEvent(123L, "ORD1234", new BigDecimal("88.00"));

        Message message = converter.toMessage(event, new MessageProperties());
        Object back = converter.fromMessage(message);

        assertThat(back).isEqualTo(event);
    }
}
```

`order-service/src/test/java/com/example/order/mq/OrderMqConsumerTest.java`：
```java
package com.example.order.mq;

import com.example.order.mapper.OrderMapper;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.InjectMocks;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;

import java.math.BigDecimal;

import static org.mockito.Mockito.verify;

@ExtendWith(MockitoExtension.class)
class OrderMqConsumerTest {

    @Mock
    private OrderMapper orderMapper;

    @InjectMocks
    private OrderMqConsumer consumer;

    @Test
    void consumeMarksOrderNotified() {
        OrderCreatedEvent event = new OrderCreatedEvent(123L, "ORD1234", new BigDecimal("88.00"));

        consumer.onOrderCreated(event);

        verify(orderMapper).updateStatus(123L, 1);
    }
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `cd order-service && docker run --rm -v "$PWD":/app -w /app maven:3.9-eclipse-temurin-21 mvn -q test`
Expected: 编译失败。

- [ ] **Step 3: 加依赖与配置**

`order-service/pom.xml` 追加：
```xml
    <dependency>
      <groupId>org.springframework.boot</groupId>
      <artifactId>spring-boot-starter-amqp</artifactId>
    </dependency>
```

`application.yml` 追加：
```yaml
spring:
  rabbitmq:
    host: rabbitmq
    port: 5672
    username: ${RABBITMQ_USER:demo}
    password: ${RABBITMQ_PASSWORD:demo123456}
```

- [ ] **Step 4: 实现消息模型与配置**

`order-service/src/main/java/com/example/order/mq/OrderCreatedEvent.java`：
```java
package com.example.order.mq;

import java.math.BigDecimal;

/** 订单创建事件消息体（Jackson 序列化为 JSON） */
public record OrderCreatedEvent(Long orderId, String orderNo, BigDecimal amount) {
}
```

`order-service/src/main/java/com/example/order/mq/RabbitConfig.java`：
```java
package com.example.order.mq;

import org.springframework.amqp.core.*;
import org.springframework.amqp.support.converter.Jackson2JsonMessageConverter;
import org.springframework.amqp.support.converter.MessageConverter;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

/** RabbitMQ 交换机/队列声明 + JSON 消息转换 */
@Configuration
public class RabbitConfig {

    public static final String EXCHANGE = "order.exchange";
    public static final String QUEUE = "order.created.queue";
    public static final String ROUTING_KEY = "order.created";

    @Bean
    public DirectExchange orderExchange() {
        return new DirectExchange(EXCHANGE, true, false);
    }

    @Bean
    public Queue orderCreatedQueue() {
        return QueueBuilder.durable(QUEUE).build();
    }

    @Bean
    public Binding orderCreatedBinding(Queue orderCreatedQueue, DirectExchange orderExchange) {
        return BindingBuilder.bind(orderCreatedQueue).to(orderExchange).with(ROUTING_KEY);
    }

    /** 消息体统一走 JSON，而非默认 JDK 序列化 */
    @Bean
    public MessageConverter jacksonMessageConverter() {
        return new Jackson2JsonMessageConverter();
    }
}
```

- [ ] **Step 5: Mapper 加更新方法，Service 发消息，写消费者**

`OrderMapper` 追加：
```java
    /** 阶段 3：消费者把订单置为已通知 */
    @Update("UPDATE orders SET status = #{status} WHERE id = #{id}")
    int updateStatus(@Param("id") Long id, @Param("status") Integer status);
```
补充 import：
```java
import org.apache.ibatis.annotations.Param;
import org.apache.ibatis.annotations.Update;
```

`OrderService` 注入 RabbitTemplate 并在 create 末尾追加（其余不变）：
```java
    private final RabbitTemplate rabbitTemplate;
```
create 方法 return 之前加：
```java
        rabbitTemplate.convertAndSend(RabbitConfig.EXCHANGE, RabbitConfig.ROUTING_KEY,
                new OrderCreatedEvent(order.getId(), order.getOrderNo(), order.getAmount()));
```
补充 import：
```java
import com.example.order.mq.OrderCreatedEvent;
import com.example.order.mq.RabbitConfig;
import org.springframework.amqp.rabbit.core.RabbitTemplate;
```
（注意：`@RequiredArgsConstructor` 会自动把新注入的 RabbitTemplate 加入构造器，OrderServiceTest 需补 `@Mock RabbitTemplate rabbitTemplate;`——执行 Step 6 前先补上，见下。）

`OrderServiceTest` 修改（加 mock，否则 @InjectMocks 构造失败）：
```java
    @Mock
    private RabbitTemplate rabbitTemplate;
```
补充 import：
```java
import org.springframework.amqp.rabbit.core.RabbitTemplate;
```

`order-service/src/main/java/com/example/order/mq/OrderMqConsumer.java`：
```java
package com.example.order.mq;

import com.example.order.mapper.OrderMapper;
import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.springframework.amqp.rabbit.annotation.RabbitListener;
import org.springframework.stereotype.Component;

/** 订单创建消息消费者：模拟异步通知（日志 + 状态置 1） */
@Slf4j
@Component
@RequiredArgsConstructor
public class OrderMqConsumer {

    private final OrderMapper orderMapper;

    @RabbitListener(queues = RabbitConfig.QUEUE)
    public void onOrderCreated(OrderCreatedEvent event) {
        log.info("收到订单创建消息: orderId={}, orderNo={}, amount={}",
                event.orderId(), event.orderNo(), event.amount());
        orderMapper.updateStatus(event.orderId(), 1);
    }
}
```

- [ ] **Step 6: 运行测试确认通过**

Run: `cd order-service && docker run --rm -v "$PWD":/app -w /app maven:3.9-eclipse-temurin-21 mvn -q test`
Expected: 全部 PASS。

- [ ] **Step 7: compose 追加 rabbitmq 并重建验证**

```yaml
  rabbitmq:
    image: rabbitmq:3-management
    container_name: rabbitmq
    ports:
      - "5672:5672"
      - "15672:15672"
    environment:
      RABBITMQ_DEFAULT_USER: ${RABBITMQ_USER:-demo}
      RABBITMQ_DEFAULT_PASS: ${RABBITMQ_PASSWORD:-demo123456}
    healthcheck:
      test: ["CMD", "rabbitmq-diagnostics", "-q", "ping"]
      interval: 15s
      timeout: 10s
      retries: 10
    networks: [microservices-net]
```

在 `.env` 与 `.env.example` 追加：
```bash
RABBITMQ_USER=demo
RABBITMQ_PASSWORD=demo123456
```

同时修改 `docker-compose.yml` 中 order-service 的 depends_on（追加 rabbitmq，保证 MQ 先就绪）：
```yaml
    depends_on:
      nacos:
        condition: service_healthy
      mysql-order:
        condition: service_healthy
      rabbitmq:
        condition: service_healthy
```

Run:
```bash
docker compose up -d --build rabbitmq order-service
sleep 5
ID=$(curl -s -X POST http://localhost:8081/orders -H 'Content-Type: application/json' \
  -d '{"userId":1,"productName":"键盘","amount":399.00}' | sed 's/.*"id":\([0-9]*\).*/\1/')
sleep 3
docker exec mysql-order mysql -uroot -proot123456 -e "SELECT id, order_no, status FROM order_db.orders WHERE id=$ID;"
docker logs order-service --tail 20 | grep -i '订单创建消息' || echo "FAIL: 未见消费日志"
```
Expected: 创建订单后 3 秒内，该订单 status 从 0 变为 1，order-service 日志出现"收到订单创建消息"。浏览器打开 `http://localhost:15672`（demo/demo123456）→ Queues 页面可见 `order.created.queue` 及消息吞吐曲线。

- [ ] **Step 8: Commit**

```bash
git add order-service/ docker-compose.yml .env.example
git commit -m "feat: RabbitMQ 订单创建事件异步消费

Co-Authored-By: Claude <noreply@anthropic.com>"
```

## Task 14: 阶段 3 全栈验收 + README 补全

**Files:**
- Create: `scripts/verify-full.sh`
- Modify: `README.md`（补阶段 2/3 说明、认证使用、验收脚本）

**Interfaces:**
- Consumes: Task 1-13 全部产物
- Produces: 三阶段全栈一键启动 + 全自动验收（含认证链路）

- [ ] **Step 1: 写全量验收脚本**

`scripts/verify-full.sh`：
```bash
#!/usr/bin/env bash
# 全量验收（阶段 1+2+3）：先登录拿 token，再走认证链路
set -euo pipefail
BASE=http://localhost:8080

echo "== 1. 容器状态 =="
docker compose ps

echo "== 2. 认证：白名单 login =="
LOGIN=$(curl -s -X POST $BASE/api/auth/login -H 'Content-Type: application/json' \
  -d '{"username":"zhangsan","password":"123456"}')
echo "$LOGIN"
TOKEN=$(echo "$LOGIN" | sed 's/.*"token":"\([^"]*\)".*/\1/')
[ -n "$TOKEN" ] && [ "$TOKEN" != "$LOGIN" ] || { echo "FAIL: 登录失败"; exit 1; }

echo "== 3. 无 token 访问（应 401）=="
curl -s -o /dev/null -w "%{http_code}\n" $BASE/api/order/orders

echo "== 4. 经 nginx(80) 带 token 创建订单 =="
CREATE=$(curl -s -X POST http://localhost/api/order/orders -H 'Content-Type: application/json' \
  -H "Authorization: Bearer $TOKEN" \
  -d '{"userId":1,"productName":"全量验收商品","amount":66.00}')
echo "$CREATE"
ID=$(echo "$CREATE" | sed 's/.*"id":\([0-9]*\).*/\1/')
[ -n "$ID" ] && [ "$ID" != "$CREATE" ] || { echo "FAIL: 创建失败"; exit 1; }

echo "== 5. 缓存命中（MISS → HIT）=="
curl -si http://localhost:8080/api/order/orders/$ID -H "Authorization: Bearer $TOKEN" | grep -i 'x-cache\|HTTP/'
curl -si http://localhost:8080/api/order/orders/$ID -H "Authorization: Bearer $TOKEN" | grep -i 'x-cache\|HTTP/'

echo "== 6. Feign 用户信息（经 user-service）=="
curl -s http://localhost:8080/api/order/orders/$ID/user -H "Authorization: Bearer $TOKEN"; echo

echo "== 7. MQ：订单状态异步置 1 =="
sleep 3
docker exec mysql-order mysql -uroot -proot123456 -e "SELECT id, status FROM order_db.orders WHERE id=$ID;"

echo "== 8. 限流（应出现 429）=="
for i in $(seq 1 25); do curl -s -o /dev/null -w "%{http_code} " \
  $BASE/api/order/orders -H "Authorization: Bearer $TOKEN"; done; echo

echo "== 全量验收完成 =="
```

- [ ] **Step 2: README 补全**

README 追加（替换阶段进度节）：
```markdown
## 阶段进度

- [x] 阶段 1 最小集合：注册/配置中心、网关路由、本地缓存、网关限流（`bash scripts/verify-phase1.sh`）
- [x] 阶段 2 调用链与弹性：nginx、user-service、Feign、熔断降级、服务级限流
- [x] 阶段 3 安全与异步：认证中心、网关 JWT、RabbitMQ（`bash scripts/verify-full.sh`）

## 熔断演示（阶段 2）

```bash
docker stop user-service
curl http://localhost:8081/orders/<id>/user   # 返回兜底"用户信息暂不可用"
docker start user-service                     # 30s 后自动恢复
```

## 认证演示（阶段 3）

```bash
TOKEN=$(curl -s -X POST http://localhost:8080/api/auth/login -H 'Content-Type: application/json' \
  -d '{"username":"zhangsan","password":"123456"}' | sed 's/.*"token":"\([^"]*\)".*/\1/')
curl http://localhost:8080/api/order/orders -H "Authorization: Bearer $TOKEN"
```

## 其他入口

- RabbitMQ 管理台: http://localhost:15672 （demo/demo123456）
- 直连调试: order-service 8081 / user-service 8082 / auth-service 8083
```

- [ ] **Step 3: 全量从零验收**

Run:
```bash
docker compose down -v
docker compose up --build -d
docker compose ps
bash scripts/verify-full.sh
```
Expected: 10 容器全部 healthy；脚本 8 项全部通过（401/200 符合预期、MISS→HIT、Feign 返回用户、MQ status=1、429 出现）。

- [ ] **Step 4: Commit**

```bash
git add scripts/ README.md
git commit -m "docs: 全量验收脚本与 README 补全

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

## 附：已知风险与回退

1. **Nacos schema 下载失败**（网络）：浏览器手动下载 `https://raw.githubusercontent.com/alibaba/nacos/3.0.3/distribution/conf/mysql-schema.sql` 保存到 `nacos/mysql-schema.sql`
2. **MyBatis-Plus 3.5.12 与 Boot 3.5.4 冲突**（小概率）：降级 `mybatis-plus.version` 为 3.5.9 重试
3. **BCrypt 种子密文校验失败**：Task 11 Step 6 的排查路径（重生成密文回填 `sql/order_db.sql`，`down -v` 重建）
4. **Nacos 配置发布 API 401**：改用 Nacos 控制台手动新建（配置管理→配置列表→新建，dataId/group/content 按各任务填写）
5. **任一阶段验收失败**：按 `docker logs <容器名>` 定位，从该任务重跑；所有状态可 `docker compose down -v` 一键重置
