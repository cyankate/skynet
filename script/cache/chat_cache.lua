local skynet = require "skynet"
local BaseCache = require "cache.base_cache"
local json = require "cjson"
local ChatCacheItem = require "cache.chat_cache_item"

local ChatCache = class("ChatCache", BaseCache)

-- 缓存配置
local CACHE_CONFIG = {
    max_size = 1000,    -- 最多缓存1000个频道
    expire_time = 1800,  -- 30分钟过期
    check_interval = 180, -- 每3分钟检查过期
}

-- 初始化
function ChatCache:ctor()
    BaseCache.ctor(self, "ChatCache", "channel")
end

function ChatCache:get_channel_messages(channel_id, count)
    local obj = self:get(channel_id)
    if not obj then
        return nil, "Channel not found"
    end
    local list = {}
    for i = #obj.messages, math.max(1, #obj.messages - count + 1), -1 do
        table.insert(list, obj.messages[i])
    end
    return list
end

-- 更新频道数据
function ChatCache:update_message(channel_id, message)
    local obj = self:get(channel_id)
    if not obj then
        return false, "Channel not found"
    end
    -- 添加新消息
    table.insert(obj.messages, message)
    
    -- 只保留最近50条消息
    while #obj.messages > 20 do
        table.remove(obj.messages, 1)
    end

    self:mark_dirty(channel_id)
    return true
end

function ChatCache:new_item(channel_id)
    local obj = ChatCacheItem.new(channel_id)
    return obj
end

return ChatCache 