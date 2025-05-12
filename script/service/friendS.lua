package.path = package.path .. ";./script/?.lua;./script/utils/?.lua"

local skynet = require "skynet"
local log = require "log"
local tableUtils = require "utils.tableUtils"
local friend_cache = require "cache.friend_cache"

local friend_mgr = nil 

function add_friend(player_id, target_id)
    local operator = friend_mgr:get_friend_data(player_id)
    if not operator then
        return false
    end
    if operator.friend_map[target_id] then
        return false 
    end 
    local ret = add_apply(player_id, target_id)
    if not ret then
        return false
    end
    return true
end

function delete_friend(player_id, target_id)
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

function add_apply(player_id, target_id)
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

function delete_apply(player_id, target_id)
    local target = friend_mgr:get_friend_data(target_id)
    if not target then
        return false
    end
    target.apply_map[player_id] = nil
    friend_mgr:mark_dirty(target_id)
    return true
end

function agree_apply(player_id, target_id)
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

function reject_apply(player_id, target_id)
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

function get_friend_list(player_id)
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

function get_apply_list(player_id)
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

function on_event(event, data)
    log.info(string.format("on_event: %s, %s", event, data))
    if event == "player.login" then
        local player_id = data.player_id
        local player_name = data.player_name
        local player_data = friend_mgr:get_friend_data(player_id)
    end
end

-- 启动服务
skynet.start(function()
    -- 注册好友服务处理函数
    skynet.dispatch("lua", function(session, source, cmd, ...)
        local cmd_map = {
            add_friend = add_friend,
            delete_friend = delete_friend,
            add_apply = add_apply,
            delete_apply = delete_apply,
            agree_apply = agree_apply,
            reject_apply = reject_apply,
            get_friend_list = get_friend_list,
            get_apply_list = get_apply_list,
            on_event = on_event,
        }
        local f = cmd_map[cmd]
        if f then
            if session == 0 then
                f(...)
            else
                skynet.ret(skynet.pack(f(...)))
            end
        else
            log.error(string.format("Unknown command: %s", cmd))
        end
    end)
    
    friend_mgr = friend_cache.new()

    -- 注册事件处理
    local event = skynet.localname(".event")
    skynet.send(event, "lua", "subscribe", "player.login", skynet.self())
    skynet.send(event, "lua", "subscribe", "player.logout", skynet.self())
    
    log.info("Friend service initialized")
end)
