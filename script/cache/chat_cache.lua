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
    if not obj.messages then 
        tableUtils.print_table(obj)
    end 
    -- 添加新消息
    table.insert(obj.messages, message)
    
    -- 只保留最近50条消息
    while #obj.messages > 10 do
        table.remove(obj.messages, 1)
    end

    self:mark_dirty(channel_id)
    return true
end

function chat_cache:new_item(channel_id)
    local obj = chat_cache_item.new(channel_id)
    return obj
end

function chat_cache:load_item(channel_id)
    local data = skynet.call(".db", "lua", "get_channel_data", channel_id)
    local obj = self:new_item(channel_id)
    if channel_id == 166228 then 
        log.error("load_item %s %s", channel_id, data)
    end 
    if data then
        obj:onload(data)
    else 
        self.new_keys[channel_id] = 1
    end
    return obj
end

function chat_cache:save(channel_id, obj)
    local data = obj:onsave()
    if self.new_keys[channel_id] then
        local dbS = skynet.localname(".db")
        local ret = skynet.call(dbS, "lua", "create_channel_data", data)
        if ret then
            self.new_keys[channel_id] = nil 
            return true 
        end
        return false 
    else 
        local dbS = skynet.localname(".db")
        skynet.send(dbS, "lua", "save_channel_data", data)
        return true
    end 
end 

return chat_cache 