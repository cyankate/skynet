local skynet = require "skynet"
local BaseCache = require "cache.base_cache"
local class = require "utils.class"
local log = require "log"
local FriendCacheItem = require "cache.friend_cache_item"

local FriendCache = class("FriendCache", BaseCache)

function FriendCache:ctor()
    self.super.ctor(self, "FriendCache", "friend")
end

-- 创建新的缓存项
function FriendCache:new_item(player_id)
    local obj = FriendCacheItem.new(player_id)
    return obj
end

-- 获取缓存统计信息
function FriendCache:get_stats()
    local stats = self.super.get_stats(self)
    stats.name = "FriendCache"
    return stats
end

return FriendCache
