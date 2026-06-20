local skynet = require "skynet"
local log = require "log"

local function on_add_friend(player_id, msg)
    if not msg.target_id or not msg.message then
        log.error("Invalid add friend format")
        return false, "Invalid message format"
    end
    local friendS = skynet.localname(".friend")
    if not friendS then
        return false, "Friend service not available"
    end
    skynet.send(friendS, "lua", "add_friend", player_id, msg.target_id, msg.message)
    return true
end

local function on_delete_friend(player_id, msg)
    if not msg.target_id then
        log.error("Invalid delete friend format")
        return false, "Invalid message format"
    end
    local friendS = skynet.localname(".friend")
    if not friendS then
        return false, "Friend service not available"
    end
    skynet.send(friendS, "lua", "delete_friend", player_id, msg.target_id)
    return true
end

local function on_agree_apply(player_id, msg)
    if not msg.player_id then
        log.error("Invalid agree apply format")
        return false, "Invalid message format"
    end
    local friendS = skynet.localname(".friend")
    if not friendS then
        return false, "Friend service not available"
    end
    skynet.send(friendS, "lua", "agree_apply", player_id, msg.player_id)
    return true
end

local function on_reject_apply(player_id, msg)
    if not msg.player_id then
        log.error("Invalid reject apply format")
        return false, "Invalid message format"
    end
    local friendS = skynet.localname(".friend")
    if not friendS then
        return false, "Friend service not available"
    end
    skynet.send(friendS, "lua", "reject_apply", player_id, msg.player_id)
    return true
end

local function on_get_friend_list(player_id, msg)
    local friendS = skynet.localname(".friend")
    if not friendS then
        return false, "Friend service not available"
    end
    skynet.send(friendS, "lua", "get_friend_list", player_id)
    return true
end

local function on_get_apply_list(player_id, msg)
    local friendS = skynet.localname(".friend")
    if not friendS then
        return false, "Friend service not available"
    end
    skynet.send(friendS, "lua", "get_apply_list", player_id)
    return true
end

local function on_add_blacklist(player_id, msg)
    if not msg.target_id then
        log.error("Invalid add blacklist format")
        return false, "Invalid message format"
    end
    local friendS = skynet.localname(".friend")
    if not friendS then
        return false, "Friend service not available"
    end
    skynet.send(friendS, "lua", "add_blacklist", player_id, msg.target_id)
    return true
end

local function on_remove_blacklist(player_id, msg)
    if not msg.target_id then
        log.error("Invalid remove blacklist format")
        return false, "Invalid message format"
    end
    local friendS = skynet.localname(".friend")
    if not friendS then
        return false, "Friend service not available"
    end
    skynet.send(friendS, "lua", "remove_blacklist", player_id, msg.target_id)
    return true
end

local function on_get_black_list(player_id, msg)
    local friendS = skynet.localname(".friend")
    if not friendS then
        return false, "Friend service not available"
    end
    skynet.send(friendS, "lua", "get_black_list", player_id)
    return true
end

return {
    add_friend = on_add_friend,
    delete_friend = on_delete_friend,
    agree_apply = on_agree_apply,
    reject_apply = on_reject_apply,
    get_friend_list = on_get_friend_list,
    get_apply_list = on_get_apply_list,
    add_blacklist = on_add_blacklist,
    remove_blacklist = on_remove_blacklist,
    get_black_list = on_get_black_list,
}
