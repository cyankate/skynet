local skynet = require "skynet"
local base_cache = require "cache.base_cache"
local json = require "cjson"
local chat_cache_item = require "cache.chat_cache_item"

local chat_cache = class("chat_cache", base_cache)

-- 缓存配置
local CACHE_CONFIG = {
    max_size = 1000,    -- 最多缓存1000个频道
    expire_time = 1800,  -- 30分钟过期
    check_interval = 180, -- 每3分钟检查过期
}

-- 初始化
function chat_cache:ctor()
    base_cache.ctor(self, "chat_cache")
end

function chat_cache:get_channel_messages(channel_id, count)
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
function chat_cache:update_message(channel_id, message)
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

function chat_cache:new_item(channel_id)
    local obj = chat_cache_item.new(channel_id)
    return obj
end

function chat_cache:db_load(channel_id)
    local dbS = skynet.localname(".db")
    local data = skynet.call(dbS, "lua", "get_channel_data", channel_id)
    return data
end

function chat_cache:db_create(channel_id, obj)
    local dbS = skynet.localname(".db")
    local data = obj:onsave()
    local ret = skynet.call(dbS, "lua", "create_channel_data", data)
    return ret
end


function chat_cache:db_update(channel_id, obj)
    local dbS = skynet.localname(".db")
    local data = obj:onsave()
    local ret = skynet.call(dbS, "lua", "save_channel_data", data)
    return ret
end

return chat_cache 