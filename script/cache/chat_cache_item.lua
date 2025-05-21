local skynet = require "skynet"
local cache_item = require "cache.cache_item"

local chat_cache_item = class("chat_cache_item", cache_item)

function chat_cache_item:ctor(channel_id)
    cache_item.ctor(self, channel_id)
    self.channel_id = channel_id
    self.messages = {}
end

function chat_cache_item:onsave()
    local data = {}
    data.channel_id = self.channel_id
    data.messages = self.messages
    data.update_time = os.time()
    return data
end

function chat_cache_item:onload(_data)
    self.channel_id = _data.channel_id
    self.messages = _data.messages
end

return chat_cache_item