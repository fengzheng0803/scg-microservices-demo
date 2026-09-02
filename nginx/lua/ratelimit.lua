-- nginx 边缘层限流（access 阶段）：按客户端 IP 令牌桶限流。
-- Task 12 优化：本地令牌桶（lua_shared_dict，跨 worker 共享）——
--   - 每请求只动共享字典（微秒级，resty.lock 按 IP 串行化保证 refill+扣减原子），
--     不再每请求查 Redis；
--   - 本地桶做与旧实现完全相同的实时 refill 数学（tokens += elapsed×rate，封顶 CAP），
--     单实例下语义与旧版逐请求 Redis EVAL 完全一致（A 相位触发/隔离/恢复断言不变）；
--   - Redis 只作状态镜像：每 IP 每 SYNC_INTERVAL(0.5s) 最多 HSET 一次桶状态
--     （ratelimit:ip:<ip> key 保留——Phase 4a 验收与可观测性依赖），拒绝路径不打 Redis；
--   - 429 判定全在本地：本地 tokens < 1 即拒，X-RateLimit-Remaining 按本地剩余估算。
-- 局限（写入注释以防误用）：单 nginx 实例语义精确；多实例部署时本地桶各自放行会使
--   总限流按实例数放大，需升级为「Redis 配额分配器」变体（跨实例结算）。
-- 无 resty.lock 环境退化为每请求 Redis EVAL（旧行为，语义保真）。
-- fail-open 保留：Redis 镜像写失败仅记日志，不影响放行判定。
-- 放行时注入 X-Edge-RateLimited: 1 —— SCG 侧 EdgeRateLimitBackstopFilter 据此跳过
--   全局兜底桶（正常流量不再被限两遍；直连 8080 的旁路流量仍吃兜底桶）。
--
-- 阈值环境变量化（Task 8）：RATE_LIMIT_RPS 默认 10、RATE_LIMIT_CAP 默认 20；
--   读不到或非法值回退默认。容量态压测由 compose 注入放大值（如 100000/200000）。
--   注意：nginx.conf 必须声明 env RATE_LIMIT_RPS / env RATE_LIMIT_CAP，
--   worker 进程才会继承这两个变量（见 nginx.conf.template，同 REDIS_HOST 机制）。

local redis_conn   = require "redis_conn"
local token_bucket = require "token_bucket"

-- 读 env 数值：缺失/非法（非数字、≤0）回退默认（容错风格对齐 redis_conn.lua）
local function env_num(name, default)
    local v = os.getenv(name)
    if v == nil then
        return default
    end
    v = v:gsub("^%s+", ""):gsub("%s+$", "")
    local n = tonumber(v)
    if n == nil or n <= 0 then
        ngx.log(ngx.WARN, "[ratelimit] env ", name, " 非法（", tostring(v), "），回退默认 ", default)
        return default
    end
    return n
end

-- 限流参数：默认 10 token/s，桶容量 20（允许 20 突发）
local RATE = env_num("RATE_LIMIT_RPS", 10)
local CAPACITY = env_num("RATE_LIMIT_CAP", 20)

-- Redis 镜像间隔：每 IP 每 0.5s 最多写一次（观测/审计用，不参与判定）
local SYNC_INTERVAL = 0.5

local dict = ngx.shared.rate_limit_local

local locks = nil
local ok, lock_mod = pcall(require, "resty.lock")
if not ok then
    ngx.log(ngx.WARN, "[ratelimit] resty.lock 不可用，退化为每请求 Redis 判定")
else
    locks = lock_mod
end

local function now_ms()
    return ngx.now() * 1000
end

local function reply_429(tokens_left)
    ngx.status = 429
    ngx.header["Content-Type"] = "application/json"
    ngx.header["X-RateLimit-Remaining"] = tostring(tokens_left)
    ngx.say('{"code":429,"msg":"rate limited"}')
    ngx.exit(429)
end

-- 本地桶条目："tokens|ts|last_sync"（tokens 可为小数，refill 数学与 Redis 版一致）
local function local_get(ip)
    local v = dict:get(ip)
    if v == nil then
        return nil
    end
    local tokens, ts, last_sync = v:match("^(%d+%.?%d*)|(%d+)|(%d+)$")
    if tokens == nil then
        return nil
    end
    return tonumber(tokens), tonumber(ts), tonumber(last_sync)
end

local function local_set(ip, tokens, ts, last_sync)
    dict:set(ip, tostring(tokens) .. "|" .. tostring(ts) .. "|" .. tostring(last_sync), 60)
end

-- Redis 镜像写（best-effort，失败仅记日志，不参与判定）
local function mirror_to_redis(ip, key, tokens, ts_ms)
    local r, err = redis_conn.get()
    if not r then
        ngx.log(ngx.ERR, "[ratelimit] redis connect failed: ", err, " (镜像跳过)")
        return
    end
    local okh = r:hset(key, "tokens", tokens, "ts", ts_ms)
    if not okh then
        ngx.log(ngx.WARN, "[ratelimit] redis mirror hset 失败（镜像跳过）")
        r:set_keepalive(10000, 100)
        return
    end
    r:pexpire(key, 60000)
    r:set_keepalive(10000, 100)
end

-- 无锁退化路径：每请求 Redis 判定（旧行为）
local function legacy_path(r, key)
    local res, rerr = token_bucket.run(r, key, RATE, CAPACITY, 1)
    if not res then
        ngx.log(ngx.ERR, "[ratelimit] rate limit eval failed: ", rerr, " (fail-open)")
        return
    end
    if res[1] ~= 1 then
        r:set_keepalive(10000, 100)
        reply_429(res[2])
    end
    r:set_keepalive(10000, 100)
end

local ip  = ngx.var.remote_addr
local key = "ratelimit:ip:" .. ip
local now = now_ms()

if locks == nil then
    local r, err = redis_conn.get()
    if not r then
        ngx.log(ngx.ERR, "[ratelimit] redis connect failed: ", err, " (fail-open)")
        return
    end
    legacy_path(r, key)
    ngx.req.set_header("X-Edge-RateLimited", "1")
    return
end

-- 每请求按 IP 加锁串行化 refill+扣减（临界区仅 dict 读写，几微秒；
-- 不做快速路径——refill+扣减两笔非原子操作并发下会 lost update 绕过限流）
local lock = locks:new("rate_limit_locks", { exptime = 1, timeout = 1 })
local elapsed, lerr = lock:lock(ip)
if not elapsed then
    ngx.log(ngx.WARN, "[ratelimit] lock 获取失败（", tostring(lerr), "），fail-open 放行")
    ngx.req.set_header("X-Edge-RateLimited", "1")
    return
end

local tokens, ts, last_sync = local_get(ip)
if tokens == nil then
    -- 冷启动：整桶 CAP 本地发放（保突发语义，A 相位触发断言依赖），立即镜像一次
    tokens = CAPACITY
    ts = now
    last_sync = now
else
    tokens = math.min(CAPACITY, tokens + (now - ts) * RATE / 1000)
    ts = now
end

if tokens >= 1 then
    local_set(ip, tokens - 1, ts, last_sync)
    if now - last_sync >= SYNC_INTERVAL * 1000 then
        mirror_to_redis(ip, key, tokens - 1, now)
        last_sync = now
        local_set(ip, tokens - 1, ts, last_sync)
    end
    lock:unlock()
    ngx.req.set_header("X-Edge-RateLimited", "1")
    return
end

-- 本地判定拒绝（不打 Redis）
local_set(ip, tokens, ts, last_sync)
lock:unlock()
reply_429(0)
