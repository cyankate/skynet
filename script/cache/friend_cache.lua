local skynet = require "skynet"
local base_cache = require "cache.base_cache"
local class = require "utils.class"
local log = require "log"
local friend_cache_item = require "cache.friend_cache_item"

local friend_cache = class("friend_cache", base_cache)

-- 缓存配置
local CACHE_CONFIG = {
    max_size = 10000,    -- 最多缓存10000个玩家的好友数据
    expire_time = 3600,  -- 1小时过期
    check_interval = 300, -- 每5分钟检查过期
}

function friend_cache:ctor()
    self.super.ctor(self, "friend_cache")
    -- self.config = CACHE_CONFIG
end

-- 创建新的缓存项
function friend_cache:new_item(player_id)
    local obj = friend_cache_item.new(player_id)
    return obj
end

function friend_cache:db_load(player_id)
    local dbS = skynet.localname(".db")
    local data = skynet.call(dbS, "lua", "load_friend_data", player_id)
    return data
end


function friend_cache:db_create(player_id, obj)
    local dbS = skynet.localname(".db")
    local data = obj:onsave()
    local ret = skynet.call(dbS, "lua", "create_friend_data", player_id, data)
    return ret
end

function friend_cache:db_update(player_id, obj)
    local dbS = skynet.localname(".db")
    local data = obj:onsave()
    local ret = skynet.call(dbS, "lua", "save_friend_data", player_id, data)
    return ret
end

-- 获取缓存统计信息
function friend_cache:get_stats()
    local stats = self.super.get_stats(self)
    stats.name = "friend_cache"
    return stats
end

return friend_cache
