local skynet = require "skynet"
local base_cache = require "cache.base_cache"
local json = require "cjson"
local channel_cache_item = require "cache.channel_cache_item"

channel_cache = class("channel_cache", base_cache)

-- 缓存配置
local CACHE_CONFIG = {
    max_size = 1000,    -- 最多缓存1000个频道
    expire_time = 300,  -- 5分钟过期
    check_interval = 60, -- 每分钟检查过期
}

-- 初始化
function channel_cache:ctor()
    base_cache.ctor(self, "channel_cache")
end

function channel_cache:load_item(player_id)
    local data = skynet.call(".db", "lua", "get_player_private_channel", player_id)
    local obj = self:new_item(player_id)
    if data then
        obj:onload(data)
    else 
        self.news[player_id] = 1
    end
    return obj
end

function channel_cache:new_item(player_id)
    local obj = channel_cache_item.new(player_id)
    return obj
end

function channel_cache:save(player_id, obj)
    local data = obj:onsave()
    if self.news[player_id] then
        local dbS = skynet.localname(".db")
        local ret = skynet.call(dbS, "lua", "create_player_private_channel", data)
        if ret then
            self.news[player_id] = nil
            return true 
        end
        return false 
    else
        local dbS = skynet.localname(".db")
        local ret = skynet.send(dbS, "lua", "update_player_private_channel", data)
        return true
    end
end 

return channel_cache 