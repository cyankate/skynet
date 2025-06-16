local skynet = require "skynet"
local cache_item = require "cache.cache_item"
local private_cache_item = class("private_cache_item", cache_item)

function private_cache_item:ctor(player_id)
    cache_item.ctor(self, player_id)
    self.player_id = player_id
    self.data = {}
end

function private_cache_item:onsave()
    local data = {}
    data.player_id = self.player_id
    data.data = self.data
    return data
end

function private_cache_item:onload(data)
    self.player_id = data.player_id
    self.data = data.data
end



return private_cache_item