-- nginx 边缘层限流（access 阶段）：
--   按客户端 IP 令牌桶限流（Redis EVAL 原子扣减），超限返 429 + X-RateLimit-Remaining
-- 改写自镜像 seckill-gateway:local 的 access.lua：
--   - 去掉 seckill:start / seckill:soldout 旗标检查与 $ratelimit=off 开关
--   - 保留令牌桶参数、fail-open 与 429 响应头
-- 最小版本策略：Redis 不可用时 fail-open（放行），仅记日志。
-- 生产环境可按业务要求改为 fail-close。
-- 阈值环境变量化（Task 8）：RATE_LIMIT_RPS 默认 10、RATE_LIMIT_CAP 默认 20；
--   读不到或非法值回退默认。容量态压测由 compose 注入放大值（如 1000/2000）。
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

-- 限流参数：默认 10 token/s，桶容量 20（允许 20 突发），每请求消耗 1
local RATE = env_num("RATE_LIMIT_RPS", 10)
local CAPACITY = env_num("RATE_LIMIT_CAP", 20)

local function reply_429(tokens_left)
    ngx.status = 429
    ngx.header["Content-Type"] = "application/json"
    ngx.header["X-RateLimit-Remaining"] = tostring(tokens_left)
    ngx.say('{"code":429,"msg":"rate limited"}')
    ngx.exit(429)
end

local r, err = redis_conn.get()
if not r then
    ngx.log(ngx.ERR, "[ratelimit] redis connect failed: ", err, " (fail-open)")
    return
end

-- 按客户端源 IP 取桶 key（容器间直连保留真实源 IP；经宿主机发布端口入站会被 SNAT 坍缩为单 IP）
local key = "ratelimit:ip:" .. ngx.var.remote_addr
local res, rerr = token_bucket.run(r, key, RATE, CAPACITY, 1)
if not res then
    ngx.log(ngx.ERR, "[ratelimit] rate limit eval failed: ", rerr, " (fail-open)")
elseif res[1] ~= 1 then
    r:set_keepalive(10000, 100)
    reply_429(res[2])
end

r:set_keepalive(10000, 100)
-- 放行，nginx 继续反向代理到 gateway
