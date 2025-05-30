local skynet = require "skynet"
local log = require "log"

local RateLimiter = {}
RateLimiter.__index = RateLimiter

-- 创建令牌桶实例
function RateLimiter.new(config)
    local self = setmetatable({}, RateLimiter)
    self.tokens = config.capacity            -- 当前令牌数
    self.capacity = config.capacity          -- 桶容量
    self.rate = config.rate                  -- 令牌生成速率（每秒）
    self.last_update = skynet.now() / 100    -- 上次更新时间（秒）
    self.window_size = config.window_size or 1  -- 统计窗口大小（秒）
    self.stats = {
        total_requests = 0,     -- 总请求数
        allowed_requests = 0,   -- 允许的请求数
        rejected_requests = 0,  -- 拒绝的请求数
        last_reset = skynet.now() / 100  -- 上次统计重置时间
    }
    return self
end

-- 更新令牌数量
function RateLimiter:update()
    local now = skynet.now() / 100  -- 转换为秒
    local elapsed = now - self.last_update
    
    -- 更新令牌数量
    local new_tokens = elapsed * self.rate
    self.tokens = math.min(self.capacity, self.tokens + new_tokens)
    self.last_update = now
    
    -- 更新统计信息
    if now - self.stats.last_reset >= self.window_size then
        -- log.info("Rate limiter stats in last %d seconds: total=%d, allowed=%d, rejected=%d, current_tokens=%.2f", 
        --     self.window_size,
        --     self.stats.total_requests,
        --     self.stats.allowed_requests,
        --     self.stats.rejected_requests,
        --     self.tokens)
        
        -- 重置统计
        self.stats.total_requests = 0
        self.stats.allowed_requests = 0
        self.stats.rejected_requests = 0
        self.stats.last_reset = now
    end
end

-- 尝试获取令牌
function RateLimiter:try_acquire()
    self:update()
    self.stats.total_requests = self.stats.total_requests + 1
    
    if self.tokens >= 1 then
        self.tokens = self.tokens - 1
        self.stats.allowed_requests = self.stats.allowed_requests + 1
        return true
    end
    
    self.stats.rejected_requests = self.stats.rejected_requests + 1
    return false
end

-- 玩家限流器管理器
local PlayerRateLimiter = {}
PlayerRateLimiter.__index = PlayerRateLimiter

function PlayerRateLimiter.new(config)
    local self = setmetatable({}, PlayerRateLimiter)
    self.config = config
    self.limiters = {}  -- player_id -> {channel, private, history}
    self.cleanup_interval = 300  -- 清理间隔（秒）
    self.last_cleanup = skynet.now() / 100
    return self
end

function PlayerRateLimiter:get_player_limiters(player_id)
    -- 清理过期的限流器
    local now = skynet.now() / 100
    if now - self.last_cleanup > self.cleanup_interval then
        self:cleanup_inactive_limiters()
        self.last_cleanup = now
    end
    
    -- 获取或创建玩家的限流器
    if not self.limiters[player_id] then
        self.limiters[player_id] = {
            channel = RateLimiter.new({
                capacity = 50,     -- 每个玩家的频道消息容量
                rate = 10,         -- 每秒10条频道消息
                window_size = 5    -- 5秒统计一次
            }),
            private = RateLimiter.new({
                capacity = 30,     -- 每个玩家的私聊消息容量
                rate = 5,          -- 每秒5条私聊消息
                window_size = 5    -- 5秒统计一次
            }),
            history = RateLimiter.new({
                capacity = 20,     -- 每个玩家的历史查询容量
                rate = 2,          -- 每秒2次历史查询
                window_size = 5    -- 5秒统计一次
            }),
            last_active = now      -- 记录最后活跃时间
        }
    else
        self.limiters[player_id].last_active = now
    end
    
    return self.limiters[player_id]
end

function PlayerRateLimiter:cleanup_inactive_limiters()
    local now = skynet.now() / 100
    local inactive_threshold = now - 3600  -- 1小时未活跃的限流器将被清理
    
    local count = 0
    for player_id, limiter_data in pairs(self.limiters) do
        if limiter_data.last_active < inactive_threshold then
            self.limiters[player_id] = nil
            count = count + 1
        end
    end
    
    if count > 0 then
        log.info("Cleaned up %d inactive player rate limiters", count)
    end
end

-- 创建限流器
local function create_limiters()
    -- 全局限流器
    local global_limiters = {
        channel = RateLimiter.new({
            capacity = 200,    -- 频道消息容量
            rate = 50,          -- 每秒50条频道消息
            window_size = 5     -- 5秒统计一次
        }),
        private = RateLimiter.new({
            capacity = 200,     -- 私聊消息容量
            rate = 100,        -- 每秒200条私聊消息
            window_size = 5    -- 5秒统计一次
        }),
        history = RateLimiter.new({
            capacity = 200,     -- 历史查询容量
            rate = 50,         -- 每秒100次历史查询
            window_size = 5    -- 5秒统计一次
        })
    }
    
    -- 玩家限流器
    local player_limiters = PlayerRateLimiter.new()
    
    return {
        global = global_limiters,
        player = player_limiters
    }
end

return {
    create_limiters = create_limiters
} 