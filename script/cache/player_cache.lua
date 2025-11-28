local skynet = require "skynet"
local BaseCache = require "cache.base_cache"
local class = require "utils.class"
local log = require "log"
local PlayerCacheItem = require "cache.player_cache_item"

local PlayerCache = class("PlayerCache", BaseCache)

-- 缓存配置
local CACHE_CONFIG = {
    max_size = 10000,    -- 最多缓存10000个玩家数据
    expire_time = 3600,  -- 1小时过期
    check_interval = 300, -- 每5分钟检查过期
}

function PlayerCache:ctor()
    self.super.ctor(self, "PlayerCache", "player_odb")
end

-- 创建新的缓存项
function PlayerCache:new_item(player_id)
    local obj = PlayerCacheItem.new(player_id)
    return obj
end

-- 更新玩家信息
function PlayerCache:update_player_info(player_id, info)
    local obj = self:get(player_id)
    if not obj then
        return false, "Player not found"
    end
    obj:update_info(info)
    self:mark_dirty(player_id)
    return true
end

-- 获取玩家信息
function PlayerCache:get_player_info(player_id)
    local obj = self:get(player_id)
    if not obj then
        return nil, "Player not found"
    end
    return obj:get_info()
end

-- 获取缓存统计信息
function PlayerCache:get_stats()
    local stats = self.super.get_stats(self)
    stats.name = "PlayerCache"
    return stats
end

return PlayerCache
