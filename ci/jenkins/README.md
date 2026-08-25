# Jenkins 环境（块 2：定制镜像 + 独立 compose + UI 配置）

学习场景的本地 Jenkins：**512MB 堆内存、按需启停、不随微服务栈自动启动**。
用于跑 `ci/tests/` 系统测试套件与后续流水线（`ci/Jenkinsfile`，块 3 提供）。

## 目录

| 文件 | 作用 |
|------|------|
| `Dockerfile` | 定制镜像：官方 lts-jdk21 + 512MB 堆 + pytest 工具链 + docker CLI |
| `docker-compose.yml` | 独立 compose：端口 8088、持久化卷、docker.sock、接入 microservices-net |
| `ci/tests/` | pytest 系统测试套件（块 1 交付） |

## 启动

前置：微服务栈（主 docker-compose.yml）已启动——Jenkins 接入其 `microservices-net` 网络，
主栈不在时该 external 网络不存在，compose 会报错（学习场景按需启停，可接受）。

```bash
docker compose -f ci/jenkins/docker-compose.yml up -d
```

## 初始密码

安装向导（首次登录 http://localhost:8088）需要初始管理员密码，两种取法：

```bash
# 方式一：docker logs
docker logs jenkins | grep -A2 "Initial admin password"

# 方式二：容器内读文件
docker exec jenkins cat /var/jenkins_home/secrets/initialAdminPassword
```

## 插件安装（最少集）

向导"Customize Jenkins"选 **Select plugins to install**，安装：

1. **Pipeline**（pipeline 语法、Pipeline: Groovy 等）
2. **JUnit**（pytest 的 JUnit XML 报告转测试趋势图）
3. **Git**（SCM 拉代码）

> 可选：**Blue Ocean**（更友好的流水线可视化），学习场景不是必须。

安装较慢属正常，可稍等或直接"Continue"后到 *系统管理 → 插件管理* 补装。

## 创建 Pipeline 作业（对接 ci/Jenkinsfile）

1. 首页 → **新建任务** → 名称 `scg-microservices-ci` → 类型 **Pipeline** → OK
2. **Pipeline** 区块：
   - Definition: **Pipeline script from SCM**
   - SCM: **Git**
   - Repository URL: `https://github.com/fengzheng0803/scg-microservices-demo.git`
   - Branches to build: `feature/scg-microservices`
   - **Script Path: `ci/Jenkinsfile`**（块 3 交付；前提：分支已 push 到 GitHub，公开仓库无需凭据）
3. 保存后点 **立即构建**；构建日志在 *Build History → #1 → Console Output*
4. 构建成功后，`系统测试` stage 的 JUnit XML 会上到 *构建页 → 测试结果趋势*（9 个用例）

> **自动化建作业（块 3 验证用，不用浏览器 UI）**：等首次登录完成后，REST 两步即可，
> 无需手点向导（详见块 3 报告 `jenkins-3-report.md`）：
>
> ```bash
> # 1. 造作业（config.xml 为 flow-definition + CpsScmFlowDefinition，SCM 指向公开仓库）
> curl --noproxy '*' -u admin:<密码> -H "Jenkins-Crumb: $(curl --noproxy '*' -u admin:<密码> -s http://localhost:8088/crumbIssuer/api/json | jq -r .crumb)" \
>   -X POST -H "Content-Type: application/xml" --data-binary @config.xml \
>   "http://localhost:8088/createItem?name=scg-microservices-ci"
> # 2. 触发构建
> curl --noproxy '*' -u admin:<密码> -H "Jenkins-Crumb: <同上>" -X POST \
>   "http://localhost:8088/job/scg-microservices-ci/build"
> ```
>
> 用 CLI 同理：`jenkins-cli.jar create-job scg-microservices-ci < config.xml`（需宿主装 Java，本机走 REST）。

## 内存验证

```bash
docker stats jenkins --no-stream
# 预期：MEM USAGE ~ 500MB 级（JAVA_OPTS=-Xmx512m 生效）
```

## 停止（按需启停）

```bash
# 停（保留容器，可再启动，配置/任务都在 jenkins_home 卷里）
docker compose -f ci/jenkins/docker-compose.yml stop

# 再启动
docker compose -f ci/jenkins/docker-compose.yml up -d

# 彻底删除（卷保留，配置不丢）
docker compose -f ci/jenkins/docker-compose.yml down
```

## 已实测的连通性（块 2 验收）

| 检查项 | 命令 | 结果 |
|--------|------|------|
| Web 登录页 | `curl --noproxy '*' -I http://localhost:8088` | HTTP 200 |
| pytest 工具链 | `docker exec jenkins python3 -c "import pytest, requests, pymysql"` | 无报错 |
| docker.sock | `docker exec jenkins docker ps` | 列出宿主容器 |
| 微服务栈网络 | `docker exec jenkins curl -s http://gateway:8080/actuator/health` | `{"status":"UP"}` |
| 内存 | `docker stats jenkins --no-stream` | ~512MB 级 |
