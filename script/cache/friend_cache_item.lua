local skynet = require "skynet"
local cache_item = require "cache.cache_item"

local friend_cache_item = class("friend_cache_item", cache_item)

function friend_cache_item:ctor(player_id)
    cache_item.ctor(self, player_id)
    self.player_id = player_id
    self.friend_map = {}  -- 好友列表
    self.apply_map = {}   -- 好友申请列表
    self.black_list = {}  -- 黑名单列表
    self.friend_info = {} -- 好友详细信息
end

function friend_cache_item:onsave()
    local ret = {}
    ret.player_id = self.player_id
    ret.data = {
        friend_map = self.friend_map,
        apply_map = self.apply_map,
        black_list = self.black_list,
        friend_info = self.friend_info
    }
    return ret
end

function friend_cache_item:onload(ret)
    self.player_id = ret.player_id
    if ret.data then
        self.friend_map = ret.data.friend_map or {}
        self.apply_map = ret.data.apply_map or {}
        self.black_list = ret.data.black_list or {}
        self.friend_info = ret.data.friend_info or {}
    end
end

-- 添加好友
function friend_cache_item:add_friend(friend_id, friend_info)
    if self.friend_map[friend_id] then
        return false, "Already friend"
    end
    if self.black_list[friend_id] then
        return false, "In black list"
    end
    self.friend_map[friend_id] = os.time()
    self.friend_info[friend_id] = friend_info
    return true
end

-- 删除好友
function friend_cache_item:remove_friend(friend_id)
    if not self.friend_map[friend_id] then
        return false, "Not friend"
    end
    self.friend_map[friend_id] = nil
    self.friend_info[friend_id] = nil
    return true
end

-- 添加好友申请
function friend_cache_item:add_apply(player_id, message)
    if self.apply_map[player_id] then
        return false, "Already applied"
    end
    if self.friend_map[player_id] then
        return false, "Already friend"
    end
    if self.black_list[player_id] then
        return false, "In black list"
    end
    self.apply_map[player_id] = {
        time = os.time(),
        message = message
    }
    return true
end

-- 删除好友申请
function friend_cache_item:remove_apply(player_id)
    if not self.apply_map[player_id] then
        return false, "No apply"
    end
    self.apply_map[player_id] = nil
    return true
end

-- 添加到黑名单
function friend_cache_item:add_to_blacklist(player_id)
    if self.black_list[player_id] then
        return false, "Already in black list"
    end
    self.black_list[player_id] = os.time()
    -- 如果是好友，自动删除好友关系
    if self.friend_map[player_id] then
        self:remove_friend(player_id)
    end
    -- 如果有申请，自动删除申请
    if self.apply_map[player_id] then
        self:remove_apply(player_id)
    end
    return true
end

-- 从黑名单移除
function friend_cache_item:remove_from_blacklist(player_id)
    if not self.black_list[player_id] then
        return false, "Not in black list"
    end
    self.black_list[player_id] = nil
    return true
end

-- 获取好友列表
function friend_cache_item:get_friend_list()
    local list = {}
    for id, time in pairs(self.friend_map) do
        table.insert(list, {
            player_id = id,
            name = "name_" .. id,
        })
    end
    return list
end

-- 获取申请列表
function friend_cache_item:get_apply_list()
    local list = {}
    for id, data in pairs(self.apply_map) do
        table.insert(list, {
            player_id = id,
            name = "name_" .. id,
            apply_time = data.time,
            message = data.message
        })
    end
    return list
end

-- 获取黑名单列表
function friend_cache_item:get_black_list()
    local list = {}
    for id, time in pairs(self.black_list) do
        table.insert(list, {
            player_id = id,
            name = "name_" .. id,
            time = time,
        })
    end
    return list
end

-- 检查是否是好友
function friend_cache_item:is_friend(player_id)
    return self.friend_map[player_id] ~= nil
end

-- 检查是否在黑名单中
function friend_cache_item:is_in_blacklist(player_id)
    return self.black_list[player_id] ~= nil
end

-- 检查是否有申请
function friend_cache_item:has_apply(player_id)
    return self.apply_map[player_id] ~= nil
end

return friend_cache_item 