local skynet = require "skynet"
local base_cache = require "cache.base_cache"
local class = require "utils.class"
local log = require "log"
local friend_cache_item = require "cache.friend_cache_item"

local friend_cache = class("friend_cache", base_cache)

function friend_cache:ctor()
    self.super.ctor(self, "friend_cache", "friend")
end

-- 创建新的缓存项
function friend_cache:new_item(player_id)
    local obj = friend_cache_item.new(player_id)
    return obj
end

-- 获取缓存统计信息
function friend_cache:get_stats()
    local stats = self.super.get_stats(self)
    stats.name = "friend_cache"
    return stats
end

return friend_cache
