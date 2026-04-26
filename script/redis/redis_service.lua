local skynet = require "skynet"
local redis = require "skynet.db.redis"
local service_ctx = require "runtime.service_ctx"

local M = service_ctx.get("redis.redis", {})
M.pool = M.pool or {}
M.config = M.config or { host = "127.0.0.1", port = 6379, db = 0, auth = nil, pool_size = 8, max_retry = 3 }
local pool = M.pool
local config = M.config

local function new_connection()
    local db = redis.connect({ host = config.host, port = config.port, db = config.db, auth = config.auth })
    return db
end

local function get_connection()
    local conn = table.remove(pool)
    if conn then
        local ok = pcall(conn.ping, conn)
        if ok then return conn end
    end
    return new_connection()
end

local function release_connection(conn)
    if #pool < config.pool_size then table.insert(pool, conn) else conn:disconnect() end
end

local function do_command(cmd, ...)
    local retry = 0
    while retry < config.max_retry do
        local conn = get_connection()
        if not conn then
            skynet.sleep(100)
            retry = retry + 1
            goto continue
        end
        local ok, result = pcall(conn[cmd], conn, ...)
        release_connection(conn)
        if ok then return result end
        retry = retry + 1
        skynet.sleep(100)
        ::continue::
    end
    return nil, "Redis command failed after retries"
end

function M.init(conf)
    config = table.copy(config)
    for k, v in pairs(conf or {}) do config[k] = v end
    M.config = config
    for i = 1, config.pool_size do
        local conn = new_connection()
        if conn then table.insert(pool, conn) end
    end
end

function M.get(key) return do_command("get", key) end
function M.mget(...) return do_command("mget", ...) end
function M.set(key, value) return do_command("set", key, value) end
function M.mset(...) return do_command("mset", ...) end
function M.setex(key, seconds, value) return do_command("setex", key, seconds, value) end
function M.del(key) return do_command("del", key) end
function M.hget(key, field) return do_command("hget", key, field) end
function M.hset(key, field, value) return do_command("hset", key, field, value) end
function M.hmget(key, ...) return do_command("hmget", key, ...) end
function M.hmset(key, ...) return do_command("hmset", key, ...) end
function M.hdel(key, field) return do_command("hdel", key, field) end
function M.hgetall(key) return do_command("hgetall", key) end
function M.lpush(key, ...) return do_command("lpush", key, ...) end
function M.rpush(key, ...) return do_command("rpush", key, ...) end
function M.lpop(key) return do_command("lpop", key) end
function M.rpop(key) return do_command("rpop", key) end
function M.lrange(key, start, stop) return do_command("lrange", key, start, stop) end
function M.sadd(key, ...) return do_command("sadd", key, ...) end
function M.srem(key, ...) return do_command("srem", key, ...) end
function M.smembers(key) return do_command("smembers", key) end
function M.sismember(key, member) return do_command("sismember", key, member) end
function M.zadd(key, score, member) return do_command("zadd", key, score, member) end
function M.zrem(key, member) return do_command("zrem", key, member) end
function M.zrange(key, start, stop, withscores) if withscores then return do_command("zrange", key, start, stop, "WITHSCORES") end return do_command("zrange", key, start, stop) end
function M.zrevrange(key, start, stop, withscores) if withscores then return do_command("zrevrange", key, start, stop, "WITHSCORES") end return do_command("zrevrange", key, start, stop) end
function M.exists(key) return do_command("exists", key) end
function M.expire(key, seconds) return do_command("expire", key, seconds) end
function M.ttl(key) return do_command("ttl", key) end
function M.incr(key) return do_command("incr", key) end
function M.incrby(key, increment) return do_command("incrby", key, increment) end

function M.multi_exec(commands)
    local conn = get_connection()
    if not conn then return nil, "Failed to get connection" end
    local ok, result = pcall(function()
        conn:multi()
        for _, cmd in ipairs(commands) do conn[cmd[1]](conn, table.unpack(cmd, 2)) end
        return conn:exec()
    end)
    release_connection(conn)
    if ok then return result end
    return nil, result
end

function M.shutdown()
    for _, conn in ipairs(pool) do conn:disconnect() end
    pool = {}
    M.pool = pool
end

function M.dispatch(cmd, ...)
    local f = M[cmd]
    if f then return f(...) end
    return nil, "Unknown command"
end

return M
