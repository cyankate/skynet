local skynet = require "skynet"
local service_ctx = require "runtime.service_ctx"
local friend_mgr = require "friend.friend_mgr"

local M = service_ctx.get("friend.friend_service", {})

function M.init()
    if M._inited then
        return true
    end
    M._inited = true

    friend_mgr.init()

    local event = skynet.localname(".event")
    if event then
        skynet.send(event, "lua", "subscribe", "player.login", skynet.self())
        skynet.send(event, "lua", "subscribe", "player.logout", skynet.self())
    end

    return true
end

function M.on_event(event_name, event_data)
    if event_name == "player.login" then
        friend_mgr.on_player_login(event_data.player_id)
    elseif event_name == "player.logout" then
        friend_mgr.on_player_logout(event_data.player_id)
    end
end

function M.add_friend(player_id, target_id, apply_info)
    return friend_mgr.add_friend(player_id, target_id, apply_info)
end

function M.delete_friend(player_id, target_id)
    return friend_mgr.delete_friend(player_id, target_id)
end

function M.agree_apply(player_id, target_id)
    return friend_mgr.agree_apply(player_id, target_id)
end

function M.reject_apply(player_id, target_id)
    return friend_mgr.reject_apply(player_id, target_id)
end

function M.get_friend_list(player_id)
    return friend_mgr.get_friend_list(player_id)
end

function M.get_apply_list(player_id)
    return friend_mgr.get_apply_list(player_id)
end

function M.add_blacklist(player_id, target_id)
    return friend_mgr.add_blacklist(player_id, target_id)
end

function M.remove_blacklist(player_id, target_id)
    return friend_mgr.remove_blacklist(player_id, target_id)
end

function M.get_black_list(player_id)
    return friend_mgr.get_black_list(player_id)
end

function M.custom_stats()
    return friend_mgr.cache:get_stats()
end

return M
