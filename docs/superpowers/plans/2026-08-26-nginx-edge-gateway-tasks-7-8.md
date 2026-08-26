# nginx 边缘层 + 全架构压测（Task 7/8 重排）实施计划

> 状态：待用户批准
> 日期：2026-08-26
> 前置：阶段 1 已完成（master=29d5eda）；本计划批准前不派发任何实现者
> 任务序列变更：原 Task 10（nginx 边缘）提前为 **新 Task 7**；新增 **Task 8**（压测）；
> 原 Task 7-9（user-service / Feign / 熔断 / 服务级限流）顺延为 Task 9-11（原计划 Task 10 内容被本计划取代）。

## 1. 背景与目标

- 边缘入口：nginx（OpenResty 1.31.1.1，本地镜像 `seckill-gateway:local`）监听 80，转发 `gateway:8080`。
- 限流职责分层：**nginx 按客户端 IP 限流（主）** + **SCG 全局兜底桶（副，语义改名）**。
- 3 个客户端容器（可参数扩展至 10）充当独立 IP 的用户，验证按 IP 限流 + 提供压测能力。
- 按需启动：nginx/客户端均为 `docker compose up -d nginx` 式增量拉起（已实测多条 `up -d` 累加、不需 profiles，8-25 的"不加 profiles"决定维持）。

## 2. 已定决策（用户拍板，2026-08-26）

| # | 决策 |
|---|---|
| D1 | SCG 限流**保留**，语义改为**全局兜底桶**（ipKeyResolver → globalKeyResolver，key 返回常量） |
| D2 | nginx 使用**本地镜像 `seckill-gateway:local`**（OpenResty 1.31.1.1），IP 限流走 lua + Redis |
| D3 | nginx 按需起 = "要它时能单独起"（`up -d nginx`），**不需要 profiles** |
| D4 | 3 个客户端容器一键拉起、可参数扩展到 10 个；压测工具 **hey** |
| D5 | Task 7 = nginx 边缘层 + IP 限流迁移 + 客户端容器 + 限流验收；Task 8 = 全架构压测（吞吐/并发） |

## 3. 设计裁决（基于 workflow 探查事实）

### R1：镜像 `seckill-gateway:local` 的接入方式（事实）

Workflow agent 实测镜像内部结构：

- **配置注入**：Entrypoint `/usr/local/bin/gateway-entrypoint` 每次启动用 `envsubst '${BACKEND_HOST}'` 把 `/etc/nginx/nginx.conf.template` 渲染到 `/usr/local/openresty/nginx/conf/nginx.conf`。→ **直接挂载 nginx.conf 会被启动时覆盖；必须挂载我们自己的 `nginx.conf.template`**（模板变量仅 `${BACKEND_HOST}`）。
- **端口固定**：upstream 端口硬编码 8080（`gateway` 服务正好是 8080 ✓），BACKEND_HOST 用环境变量 `gateway` 指到网关。
- **lua-resty-redis 内置**：`/usr/local/openresty/lualib/resty/redis.lua`（0.32），`lua_package_path` 已含 `/etc/nginx/lua/?.lua`。
- **现成限流脚本**（旧秒杀项目产物，直接改写复用，不重写）：`access.lua`（按客户端 IP 令牌桶：RATE=10/s、CAPACITY=20、Redis EVAL 原子、429 + X-RateLimit-Remaining、**Redis 不可用 fail-open**）、`token_bucket.lua`（通用令牌桶 Lua）、`redis_conn.lua`（连接辅助，200ms 超时、pcall 回退）。
- **模板要点**：`env REDIS_HOST/REDIS_PORT` 声明（worker 里 os.getenv 读）、`resolver 127.0.0.11`（Docker DNS，供 cosocket 解析 Redis 主机名）、access_log 走 stdout、`/health` 返回 200。
- 原模板只监听 8081 且仅 `/seckill` location——**我们挂载自己的模板**：listen 80、`location /` 全量转发 + `access_by_lua_file` 挂限流。

### R2：SCG 全局兜底桶的容量（裁决，需用户确认）

**冲突**：全局桶若维持 10/s+20 突发，3 客户端经 nginx 各 10/s 的正常流量（合计 30/s）会被 SCG 全拦——兜底桶变成主瓶颈，D1 的"兜底"语义不成立，Task 8 限流态断言（合计 30/s 通过）也必失败。

**裁决建议**：SCG 全局桶 **replenishRate 10→100/s，burstCapacity 保持 20**。理由：

1. 兜底语义：正常负载（3×10=30/s）远低于 100/s，兜底不干扰正常流量；绕过 nginx 直连 8080 的洪水仍被 100/s 封顶（兜底仍起作用）
2. 突发保持 20 不动 → **现有测试几乎零改动**：ci/tests/test_ratelimit.py（30 并发→≥3 个 429；随后 6 并发→≥1）、verify-phase1.sh（25 连发）都是**突发驱动**，20 突发不变则断言照旧成立
3. 兜底演示：直连 gateway 8080 灌 2s×50 并发 ≈ 100 请求 → 约 20 通过 + 80 个 429，行为清晰可断言

（备选：维持 10/20 不变——则 Task 8 限流态断言改为"合计 10/s 被 SCG 封顶"且 nginx/SCG 429 混在一起无法归因，演示价值低，不推荐。）

### R3：客户端容器形态（裁决）

Workflow 两个 agent 方案有分歧（compose 服务 vs 裸 `docker run` 挂网络），裁决取**裸 docker run + launch-clients.sh**：

- compose 服务定义在 compose 文件里会污染主编排；且 `compose up --scale` 的副本同名同 env，无法做到"每用户差异化 QPS"
- 裸 `docker run --network microservices_microservices-net` 直接挂现有网络，Docker DNS 可解析 `nginx`/`gateway` 服务名（agent 实测确认）
- 命名 `client-1..N`，`launch-clients.sh N=10` 即扩展——满足 D4
- **SNAT 前提（已实测）**：客户端→nginx 必须是**容器间流量**（源 IP 保留）；任何经宿主机发布端口的压测都会坍缩为单 IP。脚本硬编码容器网络内目标（`http://nginx/`），头部注释明示禁止 localhost 起压。

### R4：压测工具 hey（事实）

Agent 实测三工具容器间吞吐：hey -c10 ≈ 41.8k RPS、wrk ≈ 57.5k、ab ≈ 84.2k——**吞吐均不构成约束**。hey 胜在 `-q`（每 worker QPS，总 QPS = -c × -q）内置限速——这是"每用户活跃度"旋钮，能让 3 个用户以不同速率打流、错峰触发 429；wrk 无限速、ab 无限速。**结论：hey**。镜像 bake 进 `loadgen:latest`（alpine:3.20 + apk add hey curl，本地已有 alpine:3.20）。

### R5：限流算法必须是令牌桶（事实，防验收失败）

若 lua 写成固定窗口（INCR+EXPIRE），窗口阈值设 30/s 时"并发 30 发"会 0 个 429（30≤30），Task 7 验收必失败；阈值设 10/s 则无突发语义、与 SCG 行为不一致。**必须用令牌桶**（直接复用镜像 `token_bucket.lua` 的 EVAL 实现），阈值 rate=10/s、cap=20 与 SCG 同构，断言数字可直接对齐。

## 4. Task 7：nginx 边缘层 + IP 限流迁移 + 客户端容器

**Files:**
- Create: `nginx/nginx.conf.template`（listen 80、upstream gateway:8080、/health、access_by_lua_file、env REDIS_HOST/REDIS_PORT、resolver 127.0.0.11）
- Create: `nginx/lua/ratelimit.lua`（改写自镜像 access.lua：去 seckill:start/soldout 旗标，保留令牌桶按 `$binary_remote_addr` 限流 + fail-open）、`nginx/lua/token_bucket.lua`、`nginx/lua/redis_conn.lua`（改写自镜像，三件套）
- Create: `loadgen/Dockerfile`（FROM alpine:3.20 + apk add --no-cache hey curl）
- Create: `scripts/launch-clients.sh`（N=${1:-3} 拉起 N 个客户端，幂等 rm 旧容器，支持 --idle 模式）
- Create: `scripts/verify-ratelimit-clients.sh`（Task 7 验收）
- Modify: `docker-compose.yml`（追加 nginx 服务块）
- Modify: `gateway/src/main/java/com/example/gateway/config/RateLimiterConfig.java`（ipKeyResolver→globalKeyResolver，返回常量 key）
- Modify: `gateway/src/main/resources/application.yml`（SpEL 引用改名；replenishRate 10→100 若 R2 批准）
- Modify: `scripts/verify-phase1.sh`、`ci/tests/test_ratelimit.py`、`ci/tests/test_redis.py`、`ci/tests/conftest.py`（限流语义注释更新，断言数字若 R2 批准则不回退）
- Modify: `README.md`（按需启动表补 nginx/客户端行、限流分层说明）

**Interfaces:**
- Consumes: gateway(8080)、redis(6379)
- Produces: `http://localhost/` 全链路；`nginx/lua` 在 Redis 写 `ratelimit:ip:<ip>` 桶 key
- 客户端容器：`client-1..N`，同挂 `microservices_microservices-net`，容器间以服务名互访

**Steps:**

- [ ] **Step 1: 提取镜像参考脚本**——`docker run --rm seckill-gateway:local sh -c 'cat /etc/nginx/lua/access.lua'` 等取出三件套为参考（不直接挂载镜像内脚本，避免旧项目逻辑混入）
- [ ] **Step 2: 写 nginx 模板 + lua 三件套**——模板 listen 80；`location /` 上 `access_by_lua_file /etc/nginx/lua/ratelimit.lua` + proxy_pass 到 upstream（proxy_http_version 1.1 + Connection "" keepalive，照抄镜像模板该段）；`location /health` 返回 200；lua 保留 fail-open 与 X-RateLimit-Remaining
- [ ] **Step 3: compose 追加 nginx 服务**——image `seckill-gateway:local`，挂载 `./nginx/nginx.conf.template:/etc/nginx/nginx.conf.template:ro` + `./nginx/lua:/etc/nginx/lua:ro`，env `BACKEND_HOST=gateway`、`REDIS_HOST=redis`、`REDIS_PORT=6379`，ports `80:80`，depends_on gateway healthy + redis healthy，healthcheck 用 busybox wget 打 `http://127.0.0.1/health`（**不能用 /dev/tcp——OpenResty alpine 是 ash 不是 bash**）
- [ ] **Step 4: SCG 改全局兜底**——RateLimiterConfig bean 改名 + 返回常量 "global"；application.yml SpEL 同步；replenishRate 按 R2 改 100；ci/tests 与 verify-phase1.sh 注释同步
- [ ] **Step 5: 客户端容器**——`loadgen/Dockerfile` + `scripts/launch-clients.sh`（默认 3、参数 N 扩展；容器内 `sleep infinity` 常驻 + `docker exec client-N hey ...` 按需打；`--idle` 语义即默认；启动后打印 用户/IP 表格供与 nginx 日志对账）
- [ ] **Step 6: 验收（scripts/verify-ratelimit-clients.sh）**——见 §6 Task 7 断言
- [ ] **Step 7: 提交**——`git add` + commit（"feat: nginx 边缘层 + lua 按 IP 限流 + 客户端容器"）

## 5. Task 8：全架构压测（吞吐/并发）

**Files:**
- Create: `scripts/load-test.sh`（复用 client-1..3，入口经 nginx 为主 / 直连 gateway 为对照）
- Create: `reports/`（gitignore，`load-test-<ts>.txt` + `.json` 摘要）
- Modify: `nginx/lua/ratelimit.lua`（阈值环境变量化 `RATE_LIMIT_RPS` 默认 10，lua 读 os.getenv）
- Modify: `gateway/src/main/resources/application.yml`（限流参数 `${SCG_RATE_LIMIT_RPS:100}` / `${SCG_RATE_LIMIT_BURST:20}` 占位符）+ `docker-compose.yml` 透传 env

**Interfaces:**
- Consumes: client-1..3 容器内 hey、nginx(80)、gateway(8080)
- Produces: `reports/load-test-<ts>.json`（每场景 {scenario, entry, concurrency, rps, p99, error_rate, n429}）

**Steps:**

- [ ] **Step 1: 阈值环境变量化**——nginx lua 与 SCG 限流参数均可经 env 放大（容量测试放开两层限流，结束 trap 恢复默认重建）
- [ ] **Step 2: 限流态压测（A，不改配置）**——A1 吞吐：每客户端 `hey -z 30s -q 10 -c 1 http://nginx/api/order/orders?page=1&size=1`；A2 并发洪水：`hey -z 20s -c 20` 同 URL（验证按 IP 拦截、通过量≈10/s×t+20）
- [ ] **Step 3: 容量态压测（B，放开限流）**——B1 容量（经 nginx）：`hey -z 30s -c 20 -q 15`×3 客户端（总投递 900/s）；B2 入口对比（直连 gateway 同参数，量化 nginx+lua+redis 开销）；B3 并发梯度：`-c 10/50/100` 三档（总 30/150/300 并发）
- [ ] **Step 4: 报告**——控制台分节 + reports/ 双轨输出；`.gitignore` 加 reports/
- [ ] **Step 5: 提交**

## 6. 验收断言

### Task 7（verify-ratelimit-clients.sh）

| 相位 | 断言 |
|---|---|
| 前置 | 3 客户端 IP 去重 == 3（SNAT 守卫，不成立即 FAIL）；冒烟：各客户端 `curl http://nginx/api/order/orders` == 200 |
| Phase 1/2/3（依次打爆 IP-1、IP-2、IP-3） | 触发：`hey -n 30 -c 30` → [429] ≥ 3；持续：紧跟 `hey -n 6 -c 6` → [429] ≥ 1；**隔离（每相位 2 次）**：其余两客户端 `hey -n 5 -c 5` → [429] == 0 且 [5xx] == 0；恢复：sleep 3 后同 IP 再打 → [429] == 0 |
| Phase 4（全局证据） | `redis-cli --scan --pattern 'ratelimit:ip:*'` 源 IP 去重 ≥ 3；nginx 日志 429 行 remote_addr 去重 == 3 |
| 顺序连发模式（可选强化） | 首 429 落在序号 [16, 25]（令牌桶 cap 20 + 途中 refill） |

硬性红线：限流只产生 429，**任何场景 [5xx] == 0**。

### Task 8（load-test.sh）

| 场景 | 判据 |
|---|---|
| A1 限流态吞吐 | 每客户端 RPS ∈ [9.5, 11.5]，合计 ≥ 27；[429] ≤ 10（首秒 SCG 突发边缘的裕量）；[5xx] == 0 |
| A2 限流态洪水 | 每客户端 [429] 占比 ≥ 80%；3 客户端各有独立 429（压测下按 IP 分桶仍成立）；[5xx] == 0 |
| B1 容量吞吐 | 合计 RPS ≥ 150（WSL2 折损后安全下限，目标 ≥300）；P99 ≤ 300ms；非 2xx 错误率 ≤ 0.5% |
| B2 入口对比 | RPS(直连) ≥ 0.85 × RPS(经 nginx)（lua+redis 开销 ≤15%）；[5xx] == 0 |
| B3 并发梯度 | c=10/50 错误率 ≤ 0.5%；c=100 档 ≤ 1%；RPS(c=100) ≥ 0.8 × RPS(c=50)（饱和而非崩溃） |

错误口径：hey Success rate 只认 2xx；**429 单独统计不计入错误**；错误 = 5xx + 超时 + 连接失败。

## 7. 风险与缓解

| 风险 | 缓解 |
|---|---|
| 宿主机侧起压 → SNAT 坍缩单 IP（演示归零） | 脚本目标硬编码容器网络 URL（http://nginx/），头部注释明示禁止 localhost；Phase 0 SNAT 守卫断言 |
| 镜像 bake 需一次外网（apk） | 构建一次常驻本地；busybox+wget 循环为离线兜底（吞吐差但 IP 语义不变） |
| hey `-q` 是每 worker QPS（总 = -c × -q） | 脚本注释写明换算；单客户端并发上限 ≤5、QPS 取小防打满共享 VM |
| 客户端容器重建后 IP 漂移 | 限流按运行时 remote_addr 取键，无需静态 IP；仅 --ip 预留时才耦合（不用） |
| SCG 全局桶 100/s 首秒边缘 429 | A1 断言留 ≤10 裕量；实现时以实测校准 |
| 挂载 nginx.conf 被 entrypoint 覆盖 | 只挂 nginx.conf.template（R1 已定） |

## 8. 实施流程（SDD）

计划批准后：写 task-7-brief.md（BASE=当前 feature HEAD）→ 派 Task 7 实现者 → 审查者（prompt 含"计划既定不是免检理由"条款）→ 验收 → 写 task-8-brief.md → 同流程 → 阶段 2（新序列 Task 9-11）→ 原 Task 12-14（阶段 3）→ 最终全分支审查（opus）→ 按阶段 merge master + push。
