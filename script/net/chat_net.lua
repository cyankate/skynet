local skynet = require "skynet"
local log = require "log"

local function on_send_channel_message(player_id, msg)
    if not msg.channel_id or not msg.content then
        log.error("Invalid channel message format")
        return false, "Invalid message format"
    end
    local chatS = skynet.localname(".chat")
    if not chatS then
        return false, "Chat service not available"
    end
    return skynet.send(chatS, "lua", "send_channel_message", msg.channel_id, player_id, msg.content)
end

local function on_send_private_message(player_id, msg)
    if not msg.to_player_id or not msg.content then
        log.error("Invalid private message format")
        return false, "Invalid message format"
    end
    local chatS = skynet.localname(".chat")
    if not chatS then
        log.error("Chat service not available")
        return false, "Chat service not available"
    end
    return skynet.send(chatS, "lua", "send_private_message", player_id, msg.to_player_id, msg.content)
end

local function on_get_channel_list(player_id, msg)
    local chatS = skynet.localname(".chat")
    if not chatS then
        return nil, "Chat service not available"
    end
    local channels = skynet.send(chatS, "lua", "get_channel_list", player_id)
    return {
        channels = channels,
    }
end

local function on_get_channel_history(player_id, msg)
    if not msg.channel_id then
        log.error("Invalid get channel history format")
        return false, "Invalid format"
    end
    local chatS = skynet.localname(".chat")
    if not chatS then
        return nil, "Chat service not available"
    end
    local history = skynet.send(chatS, "lua", "get_channel_history", msg.channel_id, msg.count, player_id)
    return {
        history = history,
    }
end

local function on_get_private_history(player_id, msg)
    if not msg.player_id then
        log.error("Invalid get private history format")
        return false, "Invalid format"
    end
    local chatS = skynet.localname(".chat")
    if not chatS then
        return nil, "Chat service not available"
    end
    local history = skynet.send(chatS, "lua", "get_private_history", player_id, msg.player_id, msg.count)
    return {
        history = history,
    }
end

return {
    send_channel_message = on_send_channel_message,
    send_private_message = on_send_private_message,
    get_channel_list = on_get_channel_list,
    get_channel_history = on_get_channel_history,
    get_private_history = on_get_private_history,
}
