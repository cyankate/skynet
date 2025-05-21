local skynet = require "skynet"
local log = require "log"
local tableUtils = require "utils.tableUtils"
local user_mgr = require "user_mgr"

function on_add_item(_player_id, _msg)
    local player = user_mgr.get_player_obj(_player_id)
    if not player then
        return false, "Player not found"
    end
    
    player:add_item(_msg.item_id, _msg.count)
    return true
end 

function on_change_name(_player_id, _msg)
    local player = user_mgr.get_player_obj(_player_id)
    if not player then
        return false, "Player not found"
    end
    
    player:change_name(_msg.name)
    return true
end 

function on_signin(_player_id, _msg)
    local player = user_mgr.get_player_obj(_player_id)
    if not player then
        return false, "Player not found"
    end
    
    player:signin()
    return true
end 

-- 处理发送频道消息
function on_send_channel_message(_player_id, _msg)
    --log.debug(string.format("on_send_channel_message %s, player_id: %s", tableUtils.serialize_table(_msg), _player_id))
    
    -- 消息格式验证
    if not _msg.channel_id or not _msg.content then
        log.error("Invalid channel message format")
        return false, "Invalid message format"
    end
    
    -- 直接调用chatS发送频道消息
    local chatS = skynet.localname(".chat")
    if not chatS then
        return false, "Chat service not available"
    end
    
    return skynet.call(chatS, "lua", "send_channel_message", _msg.channel_id, _player_id, _msg.content)
end

-- 处理发送私聊消息
function on_send_private_message(_player_id, _msg)
    --log.debug(string.format("on_send_private_message %s", tableUtils.serialize_table(_msg)))
    
    -- 消息格式验证
    if not _msg.to_player_id or not _msg.content then
        log.error("Invalid private message format")
        return false, "Invalid message format"
    end
    
    -- 直接调用chatS发送私聊消息
    local chatS = skynet.localname(".chat")
    if not chatS then
        log.error("Chat service not available")
        return false, "Chat service not available"
    end
    
    return skynet.call(chatS, "lua", "send_private_message", _player_id, _msg.to_player_id, _msg.content)
end

-- 处理获取频道列表
function on_get_channel_list(_player_id, _msg)
    -- 直接调用chatS获取频道列表
    local chatS = skynet.localname(".chat")
    if not chatS then
        return nil, "Chat service not available"
    end
    
    local channels = skynet.call(chatS, "lua", "get_channel_list")
    return {
        channels = channels
    }
end

-- 处理获取频道历史消息
function on_get_channel_history(_player_id, _msg)
    --log.debug(string.format("on_get_channel_history %s", tableUtils.serialize_table(_msg)))
    
    -- 消息格式验证
    if not _msg.channel_id then
        log.error("Invalid get channel history format")
        return false, "Invalid format"
    end
    
    -- 直接调用chatS获取频道历史消息
    local chatS = skynet.localname(".chat")
    if not chatS then
        return nil, "Chat service not available"
    end
    
    local history = skynet.call(chatS, "lua", "get_channel_history", _msg.channel_id, _msg.count)
    return {
        history = history
    }
end

-- 处理获取私聊历史消息
function on_get_private_history(_player_id, _msg)
    --log.debug(string.format("on_get_private_history %s", tableUtils.serialize_table(_msg)))
    
    -- 消息格式验证
    if not _msg.player_id then
        log.error("Invalid get private history format")
        return false, "Invalid format"
    end
    
    -- 直接调用chatS获取私聊历史消息
    local chatS = skynet.localname(".chat")
    if not chatS then
        return nil, "Chat service not available"
    end
    
    local history = skynet.call(chatS, "lua", "get_private_history", _player_id, _msg.player_id, _msg.count)
    return {
        history = history
    }
end

function on_add_score(_player_id, _msg)
    local player = user_mgr.get_player_obj(_player_id)
    if not player then
        return false, "Player not found"
    end
    
    player:add_score(_msg.score)
    local score = player:get_score()
    local rankS = skynet.localname(".rank")
    skynet.call(rankS, "lua", "update_rank", "score", {
        player_id = player.player_id_,
        score = score,
    })
    return true
end

local handle = {
    ["add_item"] = on_add_item,
    ["change_name"] = on_change_name,
    ["signin"] = on_signin,
    -- 聊天相关消息处理
    ["send_channel_message"] = on_send_channel_message,
    ["send_private_message"] = on_send_private_message,
    ["get_channel_list"] = on_get_channel_list,
    ["get_channel_history"] = on_get_channel_history,
    ["get_private_history"] = on_get_private_history,
    ["add_score"] = on_add_score,
}

return handle