local skynet = require "skynet"
local CacheItem = require "cache.cache_item"

local ChatCacheItem = class("ChatCacheItem", CacheItem)

function ChatCacheItem:ctor(channel_id)
    CacheItem.ctor(self, channel_id)
    self.channel_id = channel_id
    self.messages = {}
end

function ChatCacheItem:onsave()
    local data = {}
    data.channel_id = self.channel_id
    data.messages = self.messages
    data.update_time = os.time()
    return data
end

function ChatCacheItem:onload(_data)
    self.channel_id = _data.channel_id
    self.messages = _data.messages
end

return ChatCacheItem