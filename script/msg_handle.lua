
local skynet = require "skynet"
local log = require "log"
local tableUtils = require "utils.tableUtils"

function on_add_item(_msg)

end 

function on_change_name(_msg)

end 

function on_signin(_msg)
    log.debug(string.format("on_signin %s", tableUtils.serialize_table(_msg)))
end 

-- 处理发送频道消息
function on_send_channel_message(_msg)
    log.debug(string.format("on_send_channel_message %s", tableUtils.serialize_table(_msg)))
    
    -- 消息格式验证
    if not _msg.channel_id or not _msg.content then
        log.error("Invalid channel message format")
        return false, "Invalid message format"
    end
    
    -- 发送频道消息
    return skynet.call(skynet.self(), "lua", "send_channel_message", _msg.channel_id, _msg.content)
end

-- 处理发送私聊消息
function on_send_private_message(_msg)
    log.debug(string.format("on_send_private_message %s", tableUtils.serialize_table(_msg)))
    
    -- 消息格式验证
    if not _msg.to_player_id or not _msg.content then
        log.error("Invalid private message format")
        return false, "Invalid message format"
    end
    
    -- 发送私聊消息
    return skynet.call(skynet.self(), "lua", "send_private_message", _msg.to_player_id, _msg.content)
end

-- 处理获取频道列表
function on_get_channel_list(_msg)
    log.debug("on_get_channel_list")
    
    -- 获取频道列表
    return skynet.call(skynet.self(), "lua", "get_channel_list")
end

-- 处理加入频道
function on_join_channel(_msg)
    log.debug(string.format("on_join_channel %s", tableUtils.serialize_table(_msg)))
    
    -- 消息格式验证
    if not _msg.channel_id then
        log.error("Invalid join channel format")
        return false, "Invalid format"
    end
    
    -- 加入频道
    return skynet.call(skynet.self(), "lua", "join_channel", _msg.channel_id)
end

-- 处理离开频道
function on_leave_channel(_msg)
    log.debug(string.format("on_leave_channel %s", tableUtils.serialize_table(_msg)))
    
    -- 消息格式验证
    if not _msg.channel_id then
        log.error("Invalid leave channel format")
        return false, "Invalid format"
    end
    
    -- 离开频道
    return skynet.call(skynet.self(), "lua", "leave_channel", _msg.channel_id)
end

-- 处理获取频道历史消息
function on_get_channel_history(_msg)
    log.debug(string.format("on_get_channel_history %s", tableUtils.serialize_table(_msg)))
    
    -- 消息格式验证
    if not _msg.channel_id then
        log.error("Invalid get channel history format")
        return false, "Invalid format"
    end
    
    -- 获取频道历史消息
    return skynet.call(skynet.self(), "lua", "get_channel_history", _msg.channel_id, _msg.count)
end

-- 处理获取私聊历史消息
function on_get_private_history(_msg)
    log.debug(string.format("on_get_private_history %s", tableUtils.serialize_table(_msg)))
    
    -- 消息格式验证
    if not _msg.player_id then
        log.error("Invalid get private history format")
        return false, "Invalid format"
    end
    
    -- 获取私聊历史消息
    return skynet.call(skynet.self(), "lua", "get_private_history", _msg.player_id, _msg.count)
end

-- -- 获取匹配服务
-- local matchS = skynet.uniqueservice("match")

-- -- 开始匹配
-- skynet.call(matchS, "lua", "start_match", player_id, match_def.TYPE.RANK, player_data)

-- -- 取消匹配
-- skynet.call(matchS, "lua", "cancel_match", player_id)

-- -- 准备就绪
-- skynet.call(matchS, "lua", "player_ready", player_id)

-- -- 获取匹配信息
-- local match_info = skynet.call(matchS, "lua", "get_match_info", player_id)

-- -- 获取房间信息
-- local room_info = skynet.call(matchS, "lua", "get_room_info", room_id)

-- -- 获取匹配统计
-- local stats = skynet.call(matchS, "lua", "get_match_stats")

local handle = {
    ["add_item"] = on_add_item,
    ["change_name"] = on_change_name,
    ["signin"] = on_signin,
    -- 聊天相关消息处理
    ["send_channel_message"] = on_send_channel_message,
    ["send_private_message"] = on_send_private_message,
    ["get_channel_list"] = on_get_channel_list,
    ["join_channel"] = on_join_channel,
    ["leave_channel"] = on_leave_channel,
    ["get_channel_history"] = on_get_channel_history,
    ["get_private_history"] = on_get_private_history,
}

return handle