package.path = package.path .. ";./script/?.lua;./script/utils/?.lua"

local skynet = require "skynet"
local base_cache = require "cache.base_cache"
local class = require "utils.class"
local log = require "log"
local friend_cache = class("friend_cache", base_cache)


function friend_cache:ctor()
    self.super.ctor(self)
end

function friend_cache:new_friend_data(player_id)
    return {
        friend_map = {},
        apply_map = {},
    }
end

function friend_cache:get_friend_data(player_id)
    return self:get(player_id, function(key)
        local db = skynet.localname(".db")
        local data = skynet.call(db, "lua", "load_friend_data", key)
        if data then
            return data
        end
        data = self:new_friend_data(key)
        local ret = skynet.call(db, "lua", "create_friend_data", key, data)
        if not ret then
            return nil
        end
        return data
    end)
end

function friend_cache:onsave(key, data)
    local db = skynet.localname(".db")
    skynet.send(db, "lua", "save_friend_data", key, data)
    return true
end


return friend_cache
