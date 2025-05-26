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
    self.super.ctor(self, "player_cache")
end

-- 创建新的缓存项
function player_cache:new_item(player_id)
    local obj = player_cache_item.new(player_id)
    return obj
end

-- 加载缓存项
function player_cache:load_item(player_id)
    local data = skynet.call(".db", "lua", "get_player_odb", player_id)
    local obj = self:new_item(player_id)
    if data then
        obj:onload(data)
    else 
        self.new_keys[player_id] = 1
    end
    return obj
end

-- 保存缓存项
function player_cache:save(player_id, obj)
    local data = obj:onsave()
    if self.new_keys[player_id] then
        local dbS = skynet.localname(".db")
        local ret = skynet.call(dbS, "lua", "create_player_odb", player_id, data)
        if ret then
            self.new_keys[player_id] = nil
            return true
        end
        return false
    else
        local dbS = skynet.localname(".db")
        skynet.send(dbS, "lua", "update_player_odb", player_id, data)
        return true
    end
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
