-- Redis 连接辅助（改写自镜像 seckill-gateway:local 同名脚本，语义不变）：
--   - OpenResty 镜像：resty.redis（官方 lua-resty-redis 命名空间）
--   - 本地 Ubuntu nginx：nginx.redis（Ubuntu 打包命名空间）
--   两者 API 一致，运行时按可用性选择（pcall 回退）。
--
--   连接地址可用环境变量覆盖（容器内使用）：
--     REDIS_HOST 默认 127.0.0.1
--     REDIS_PORT 默认 6379
--   本容器的 nginx.conf 声明了 env REDIS_HOST / env REDIS_PORT，
--   worker 里 os.getenv 可读到 compose 注入的值（redis:6379）。
local _M = {}

local TIMEOUT = 200 -- ms

local ok, redis = pcall(require, "resty.redis")
if not ok then
    redis = require "nginx.redis"
end

-- 返回连接对象；失败返回 nil, err
function _M.get()
    local host = os.getenv("REDIS_HOST")
    if host == nil or host == "" then
        host = "127.0.0.1"
    end
    -- 去除首尾空白（误配置时避免连接串混入空白）
    host = host:gsub("^%s+", ""):gsub("%s+$", "")
    if host == "" then
        host = "127.0.0.1"
    end

    -- 非数字的 REDIS_PORT（如误填字符串）回退默认值，避免 connect 报晦涩错误
    local port = tonumber(os.getenv("REDIS_PORT")) or 6379

    local r = redis.new()
    r:set_timeout(TIMEOUT)
    local okc, err = r:connect(host, port)
    if not okc then
        return nil, err
    end
    return r
end

return _M
