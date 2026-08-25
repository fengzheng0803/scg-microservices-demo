# Jenkins 定制镜像（学习场景，按需启停）
# 基础镜像：官方 lts + JDK21（Ubuntu 22.04 系），保持官方 ENTRYPOINT 启动方式不变
FROM jenkins/jenkins:lts-jdk21

# 堆内存上限 512MB：
#   - Jenkins 默认按物理内存 1/4 分配（本机通常 4~8G 起步），学习场景用不满
#   - 与"按需启停"定位一致：降低常驻占用，docker stats 可验证 ~512MB 级
ENV JAVA_OPTS=-Xmx512m

# 安装 pytest 工具链（需要 root，官方镜像默认 jenkins 用户无 apt 权限）：
#   - python3 + python3-pip：Jenkins 流水线执行 ci/tests 系统测试套件
#   - pytest/requests/pymysql 版本对齐 ci/tests/requirements.txt
#     （pytest>=7.4、requests>=2.31、pymysql>=1.1，安装时取最新满足版本）
USER root
RUN apt-get update && apt-get install -y --no-install-recommends python3 python3-pip \
    # Ubuntu 24.04 基础镜像的 python3 受 PEP 668（externally-managed）保护，pip 全局安装需显式放开；
    # 定制镜像是一次性学习环境，系统 python 被破坏无影响，--break-system-packages 最省事
    && pip3 install --break-system-packages 'pytest>=7.4' 'requests>=2.31' 'pymysql>=1.1' \
    && rm -rf /var/lib/apt/lists/*

# 安装 docker CLI：
#   - 流水线要操作宿主 Docker：构建微服务镜像、docker compose 拉起被测栈、跑容器化测试
#   - 通过挂载 /var/run/docker.sock 连宿主 daemon（见 docker-compose.yml），容器内只需 CLI
#   - 注：本基础镜像已是 Debian 13，docker.io 包只含 daemon（dockerd），CLI 拆到独立 docker-cli 包；
#     与宿主 Docker 客户端协议兼容，学习场景够用
RUN apt-get update && apt-get install -y --no-install-recommends docker-cli \
    && rm -rf /var/lib/apt/lists/*

# docker compose v2 插件（块3 实测发现 docker-cli 包不带 compose 子命令）：
#   - 按官方方式把插件二进制放进 /usr/local/lib/docker/cli-plugins/，`docker compose` 即可用
#   - 版本对齐宿主机：`docker compose version` 查得 v5.2.0（协议兼容宿主 daemon）
RUN mkdir -p /usr/local/lib/docker/cli-plugins \
    && curl -fsSL -o /usr/local/lib/docker/cli-plugins/docker-compose \
         https://github.com/docker/compose/releases/download/v5.2.0/docker-compose-linux-x86_64 \
    && chmod +x /usr/local/lib/docker/cli-plugins/docker-compose \
    && docker compose version

# 恢复官方镜像默认用户；容器以 root 运行由 compose 的 user: root 控制
# （root 仅为打通 docker.sock 权限，学习场景接受，见 docker-compose.yml 注释的 trade-off）
USER jenkins
