local skynet = require "skynet"
local redis = require "skynet.db.redis"

local CMD = {}
local pool = {}  -- Redis连接池
local config = {
    host = "127.0.0.1",
    port = 6379,
    db = 0,
    auth = nil,  -- Redis密码,没有则为nil
    pool_size = 8,  -- 连接池大小
    max_retry = 3,  -- 最大重试次数
}

-- 创建新的Redis连接
local function new_connection()
    local db = redis.connect({
        host = config.host,
        port = config.port,
        db = config.db,
        auth = config.auth
    })
    if not db then
        skynet.error("Failed to connect to Redis")
        return nil
    end
    return db
end

-- 从连接池获取连接
local function get_connection()
    -- 先尝试从池中获取
    local conn = table.remove(pool)
    if conn then
        -- 检查连接是否还有效
        local ok = pcall(conn.ping, conn)
        if ok then
            return conn
        end
    end
    
    -- 创建新连接
    return new_connection()
end

-- 将连接放回池中
local function release_connection(conn)
    if #pool < config.pool_size then
        table.insert(pool, conn)
    else
        -- 超过池大小,直接关闭
        conn:disconnect()
    end
end

-- 执行Redis命令的包装函数
local function do_command(cmd, ...)
    local retry = 0
    while retry < config.max_retry do
        local conn = get_connection()
        if not conn then
            skynet.sleep(100)  -- 等待100ms后重试
            retry = retry + 1
            goto continue
        end
        
        local ok, result = pcall(conn[cmd], conn, ...)
        release_connection(conn)
        
        if ok then
            return result
        end
        
        skynet.error("Redis command failed:", result)
        retry = retry + 1
        skynet.sleep(100)
        ::continue::
    end
    return nil, "Redis command failed after retries"
end

-- 初始化连接池
function CMD.init(conf)
    config = table.copy(config)  -- 复制默认配置
    for k, v in pairs(conf or {}) do
        config[k] = v
    end
    
    -- 预创建连接
    for i = 1, config.pool_size do
        local conn = new_connection()
        if conn then
            table.insert(pool, conn)
        end
    end
    
    skynet.error("Redis service initialized with pool size:", #pool)
end

-- String 操作
function CMD.get(key)
    return do_command("get", key)
end

function CMD.set(key, value)
    return do_command("set", key, value)
end

function CMD.setex(key, seconds, value)
    return do_command("setex", key, seconds, value)
end

function CMD.del(key)
    return do_command("del", key)
end

-- Hash 操作
function CMD.hget(key, field)
    return do_command("hget", key, field)
end

function CMD.hset(key, field, value)
    return do_command("hset", key, field, value)
end

function CMD.hmget(key, ...)
    return do_command("hmget", key, ...)
end

function CMD.hmset(key, ...)
    return do_command("hmset", key, ...)
end

function CMD.hdel(key, field)
    return do_command("hdel", key, field)
end

function CMD.hgetall(key)
    return do_command("hgetall", key)
end

-- List 操作
function CMD.lpush(key, ...)
    return do_command("lpush", key, ...)
end

function CMD.rpush(key, ...)
    return do_command("rpush", key, ...)
end

function CMD.lpop(key)
    return do_command("lpop", key)
end

function CMD.rpop(key)
    return do_command("rpop", key)
end

function CMD.lrange(key, start, stop)
    return do_command("lrange", key, start, stop)
end

-- Set 操作
function CMD.sadd(key, ...)
    return do_command("sadd", key, ...)
end

function CMD.srem(key, ...)
    return do_command("srem", key, ...)
end

function CMD.smembers(key)
    return do_command("smembers", key)
end

function CMD.sismember(key, member)
    return do_command("sismember", key, member)
end

-- Sorted Set 操作
function CMD.zadd(key, score, member)
    return do_command("zadd", key, score, member)
end

function CMD.zrem(key, member)
    return do_command("zrem", key, member)
end

function CMD.zrange(key, start, stop, withscores)
    if withscores then
        return do_command("zrange", key, start, stop, "WITHSCORES")
    end
    return do_command("zrange", key, start, stop)
end

function CMD.zrevrange(key, start, stop, withscores)
    if withscores then
        return do_command("zrevrange", key, start, stop, "WITHSCORES")
    end
    return do_command("zrevrange", key, start, stop)
end

-- 其他常用操作
function CMD.exists(key)
    return do_command("exists", key)
end

function CMD.expire(key, seconds)
    return do_command("expire", key, seconds)
end

function CMD.ttl(key)
    return do_command("ttl", key)
end

function CMD.incr(key)
    return do_command("incr", key)
end

function CMD.incrby(key, increment)
    return do_command("incrby", key, increment)
end

-- 批量执行
function CMD.multi_exec(commands)
    local conn = get_connection()
    if not conn then
        return nil, "Failed to get connection"
    end
    
    local ok, result = pcall(function()
        conn:multi()
        for _, cmd in ipairs(commands) do
            conn[cmd[1]](conn, table.unpack(cmd, 2))
        end
        return conn:exec()
    end)
    
    release_connection(conn)
    
    if ok then
        return result
    else
        return nil, result
    end
end

-- 清理连接池
function CMD.shutdown()
    for _, conn in ipairs(pool) do
        conn:disconnect()
    end
    pool = {}
end

skynet.start(function()
    skynet.dispatch("lua", function(session, source, cmd, ...)
        local f = CMD[cmd]
        if f then
            skynet.ret(skynet.pack(f(...)))
        else
            skynet.error("Unknown redis command:", cmd)
            skynet.ret(skynet.pack(nil, "Unknown command"))
        end
    end)
    skynet.register(".redis")
end) 