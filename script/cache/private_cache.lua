local skynet = require "skynet"
local BaseCache = require "cache.base_cache"
local json = require "cjson"
local PrivateCacheItem = require "cache.private_cache_item"

local PrivateCache = class("PrivateCache", BaseCache)

-- 缓存配置
local CACHE_CONFIG = {
    max_size = 1000,    -- 最多缓存1000个频道
    expire_time = 300,  -- 5分钟过期
    check_interval = 60, -- 每分钟检查过期
}

-- 初始化
function PrivateCache:ctor()
    BaseCache.ctor(self, "PrivateCache", "player_private")
end

function PrivateCache:new_item(player_id)
    local obj = PrivateCacheItem.new(player_id)
    return obj
end

return PrivateCache 