
local skynet = require "skynet"
local log = require "log"
local tableUtils = require "utils.tableUtils"
local friend_cache = require "cache.friend_cache"
require "skynet.manager"
local service_wrapper = require "utils.service_wrapper"

local friend_mgr = nil 

function CMD.add_friend(player_id, target_id)
    local operator = friend_mgr:get_friend_data(player_id)
    if not operator then
        return false
    end
    if operator.friend_map[target_id] then
        return false 
    end 
    local ret = CMD.add_apply(player_id, target_id)
    if not ret then
        return false
    end
    return true
end

function CMD.delete_friend(player_id, target_id)
    local operator = friend_mgr:get_friend_data(player_id)
    if not operator then
        return false
    end
    if not operator.friend_map[target_id] then
        return false
    end
    operator.friend_map[target_id] = nil
    friend_mgr:mark_dirty(player_id)
    return true
end

function CMD.add_apply(player_id, target_id)
    local target = friend_mgr:get_friend_data(target_id)
    if not target then
        return false
    end
    if target.apply_map[player_id] then
        return false
    end
    target.apply_map[player_id] = os.time()
    friend_mgr:mark_dirty(target_id)
    return true 
end

function CMD.delete_apply(player_id, target_id)
    local target = friend_mgr:get_friend_data(target_id)
    if not target then
        return false
    end
    target.apply_map[player_id] = nil
    friend_mgr:mark_dirty(target_id)
    return true
end

function CMD.agree_apply(player_id, target_id)
    local operator = friend_mgr:get_friend_data(player_id)
    if not operator then
        return false
    end
    if not operator.apply_map[target_id] then
        return false
    end
    operator.friend_map[target_id] = {
        name = target_id,
    }
    operator.apply_map[target_id] = nil
    friend_mgr:mark_dirty(player_id)
end

function CMD.reject_apply(player_id, target_id)
    local operator = friend_mgr:get_friend_data(player_id)
    if not operator then
        return false
    end
    if not operator.apply_map[target_id] then
        return false
    end
    operator.apply_map[target_id] = nil
    friend_mgr:mark_dirty(player_id)
    return true
end 

function CMD.get_friend_list(player_id)
    local operator = friend_mgr:get_friend_data(player_id)
    if not operator then
        return false
    end
    local list = {}
    for k, v in pairs(operator.friend_map) do
        table.insert(list, k)
    end
    return list
end

function CMD.get_apply_list(player_id)
    local operator = friend_mgr:get_friend_data(player_id)
    if not operator then
        return false
    end
    local list = {}
    for k, v in pairs(operator.apply_map) do
        table.insert(list, k)
    end
    return list
end

function CMD.on_event(event, data)
    if event == "player.login" then
        local player_id = data.player_id
        local player_name = data.player_name
        --local player_data = friend_mgr:get_friend_data(player_id)
    end
end

-- 主服务函数
local function main()
    friend_mgr = friend_cache.new()

    -- 注册事件处理
    local event = skynet.localname(".event")
    skynet.send(event, "lua", "subscribe", "player.login", skynet.self())
    skynet.send(event, "lua", "subscribe", "player.logout", skynet.self())
    
    -- 注册服务名
    skynet.register(".friend")
    
    log.info("Friend service initialized")
end

service_wrapper.create_service(main, {
    name = "friend",
})
