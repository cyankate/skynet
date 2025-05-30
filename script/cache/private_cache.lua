local skynet = require "skynet"
local base_cache = require "cache.base_cache"
local json = require "cjson"
local private_cache_item = require "cache.private_cache_item"

private_cache = class("private_cache", base_cache)

-- 缓存配置
local CACHE_CONFIG = {
    max_size = 1000,    -- 最多缓存1000个频道
    expire_time = 300,  -- 5分钟过期
    check_interval = 60, -- 每分钟检查过期
}

-- 初始化
function private_cache:ctor()
    base_cache.ctor(self, "private_cache")
end

function private_cache:new_item(player_id)
    local obj = private_cache_item.new(player_id)
    return obj
end

function private_cache:db_load(player_id)
    local dbS = skynet.localname(".db")
    local data = skynet.call(dbS, "lua", "get_player_private_channel", player_id)
    return data
end

function private_cache:db_create(player_id, obj)
    local dbS = skynet.localname(".db")
    local data = obj:onsave()
    local ret = skynet.call(dbS, "lua", "create_player_private_channel", data)
    return ret
end


function private_cache:db_update(player_id, obj)
    local dbS = skynet.localname(".db")
    local data = obj:onsave()
    local ret = skynet.call(dbS, "lua", "update_player_private_channel", data)
    return ret
end

return private_cache 