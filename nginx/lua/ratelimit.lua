-- nginx 边缘层限流（access 阶段）：
--   按客户端 IP 令牌桶限流（Redis EVAL 原子扣减），超限返 429 + X-RateLimit-Remaining
-- 改写自镜像 seckill-gateway:local 的 access.lua：
--   - 去掉 seckill:start / seckill:soldout 旗标检查与 $ratelimit=off 开关
--   - 保留令牌桶参数（rate=10/s, capacity=20）、fail-open 与 429 响应头
-- 最小版本策略：Redis 不可用时 fail-open（放行），仅记日志。
-- 生产环境可按业务要求改为 fail-close。

local redis_conn   = require "redis_conn"
local token_bucket = require "token_bucket"

-- 限流参数：10 token/s，桶容量 20（允许 20 突发），每请求消耗 1
local RATE = 10
local CAPACITY = 20

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
