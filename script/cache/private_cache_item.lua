local skynet = require "skynet"
local CacheItem = require "cache.cache_item"

local PrivateCacheItem = class("PrivateCacheItem", CacheItem)

function PrivateCacheItem:ctor(player_id)
    CacheItem.ctor(self, player_id)
    self.player_id = player_id
    self.data = {}
end

function PrivateCacheItem:onsave()
    local data = {}
    data.player_id = self.player_id
    data.data = self.data
    return data
end

function PrivateCacheItem:onload(data)
    self.player_id = data.player_id
    self.data = data.data
end



return PrivateCacheItem