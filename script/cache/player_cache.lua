local skynet = require "skynet"
local base_cache = require "cache.base_cache"
local class = require "utils.class"
local log = require "log"
local player_cache_item = require "cache.player_cache_item"

local player_cache = class("player_cache", base_cache)

-- 缓存配置
local CACHE_CONFIG = {
    max_size = 10000,    -- 最多缓存10000个玩家数据
    expire_time = 3600,  -- 1小时过期
    check_interval = 300, -- 每5分钟检查过期
}

function player_cache:ctor()
    self.super.ctor(self, "player_cache", "player_odb")
end

-- 创建新的缓存项
function player_cache:new_item(player_id)
    local obj = player_cache_item.new(player_id)
    return obj
end

-- 更新玩家信息
function player_cache:update_player_info(player_id, info)
    local obj = self:get(player_id)
    if not obj then
        return false, "Player not found"
    end
    obj:update_info(info)
    self:mark_dirty(player_id)
    return true
end

-- 获取玩家信息
function player_cache:get_player_info(player_id)
    local obj = self:get(player_id)
    if not obj then
        return nil, "Player not found"
    end
    return obj:get_info()
end

-- 获取缓存统计信息
function player_cache:get_stats()
    local stats = self.super.get_stats(self)
    stats.name = "player_cache"
    return stats
end

return player_cache
