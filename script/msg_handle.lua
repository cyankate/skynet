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
    
    return skynet.send(chatS, "lua", "send_channel_message", _msg.channel_id, _player_id, _msg.content)
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
    
    return skynet.send(chatS, "lua", "send_private_message", _player_id, _msg.to_player_id, _msg.content)
end

-- 处理获取频道列表
function on_get_channel_list(_player_id, _msg)
    -- 直接调用chatS获取频道列表
    local chatS = skynet.localname(".chat")
    if not chatS then
        return nil, "Chat service not available"
    end
    
    local channels = skynet.send(chatS, "lua", "get_channel_list")
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
    
    local history = skynet.send(chatS, "lua", "get_channel_history", _msg.channel_id, _msg.count, _player_id)
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
    
    local history = skynet.send(chatS, "lua", "get_private_history", _player_id, _msg.player_id, _msg.count)
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
    skynet.send(rankS, "lua", "update_rank", "score", {
        player_id = player.player_id_,
        score = score,
    })
    return true
end

-- 处理添加好友请求
function on_add_friend(_player_id, _msg)
    -- 消息格式验证
    if not _msg.target_id or not _msg.message then
        log.error("Invalid add friend format")
        return false, "Invalid message format"
    end
    
    -- 直接调用friendS添加好友
    local friendS = skynet.localname(".friend")
    if not friendS then
        return false, "Friend service not available"
    end
    
    skynet.send(friendS, "lua", "add_friend", _player_id, _msg.target_id, _msg.message)
    return true
end

-- 处理删除好友请求
function on_delete_friend(_player_id, _msg)
    if not _msg.target_id then
        log.error("Invalid delete friend format")
        return false, "Invalid message format"
    end
    
    local friendS = skynet.localname(".friend")
    if not friendS then
        return false, "Friend service not available"
    end
    
    skynet.send(friendS, "lua", "delete_friend", _player_id, _msg.target_id)
    return true
end

-- 处理同意好友申请
function on_agree_apply(_player_id, _msg)
    if not _msg.player_id then
        log.error("Invalid agree apply format")
        return false, "Invalid message format"
    end
    
    local friendS = skynet.localname(".friend")
    if not friendS then
        return false, "Friend service not available"
    end
    
    skynet.send(friendS, "lua", "agree_apply", _player_id, _msg.player_id)
    return true
end

-- 处理拒绝好友申请
function on_reject_apply(_player_id, _msg)
    if not _msg.player_id then
        log.error("Invalid reject apply format")
        return false, "Invalid message format"
    end
    
    local friendS = skynet.localname(".friend")
    if not friendS then
        return false, "Friend service not available"
    end
    
    skynet.send(friendS, "lua", "reject_apply", _player_id, _msg.player_id)
    return true
end

-- 处理获取好友列表
function on_get_friend_list(_player_id, _msg)
    local friendS = skynet.localname(".friend")
    if not friendS then
        return false, "Friend service not available"
    end
    
    skynet.send(friendS, "lua", "get_friend_list", _player_id)
    return true
end

-- 处理获取申请列表
function on_get_apply_list(_player_id, _msg)
    local friendS = skynet.localname(".friend")
    if not friendS then
        return false, "Friend service not available"
    end
    
    skynet.send(friendS, "lua", "get_apply_list", _player_id)
    return true
end

-- 处理加入黑名单
function on_add_blacklist(_player_id, _msg)
    if not _msg.target_id then
        log.error("Invalid add blacklist format")
        return false, "Invalid message format"
    end
    
    local friendS = skynet.localname(".friend")
    if not friendS then
        return false, "Friend service not available"
    end
    
    skynet.send(friendS, "lua", "add_blacklist", _player_id, _msg.target_id)
    return true
end

-- 处理移除黑名单
function on_remove_blacklist(_player_id, _msg)
    if not _msg.target_id then
        log.error("Invalid remove blacklist format")
        return false, "Invalid message format"
    end
    
    local friendS = skynet.localname(".friend")
    if not friendS then
        return false, "Friend service not available"
    end
    
    skynet.send(friendS, "lua", "remove_blacklist", _player_id, _msg.target_id)
    return true
end

-- 处理获取黑名单列表
function on_get_black_list(_player_id, _msg)
    local friendS = skynet.localname(".friend")
    if not friendS then
        return false, "Friend service not available"
    end
    
    skynet.send(friendS, "lua", "get_black_list", _player_id)
    return true
end

-- 麻将相关消息处理
function on_mahjong_create_room(_player_id, _msg)
    if not _msg.mode or not _msg.base_score then
        log.error("Invalid create room format")
        return false, "Invalid message format"
    end
    
    local matchS = skynet.localname(".match")
    if not matchS then
        return false, "Match service not available"
    end
    
    return skynet.send(matchS, "lua", "create_room", _player_id, 2, _msg)  -- 2表示麻将游戏
end

function on_mahjong_join_room(_player_id, _msg)
    if not _msg.room_id then
        log.error("Invalid join room format")
        return false, "Invalid message format"
    end
    
    local matchS = skynet.localname(".match")
    if not matchS then
        return false, "Match service not available"
    end
    
    return skynet.send(matchS, "lua", "join_room", _player_id, _msg.room_id)
end

function on_mahjong_leave_room(_player_id, _msg)
    if not _msg.room_id then
        log.error("Invalid leave room format")
        return false, "Invalid message format"
    end
    
    local matchS = skynet.localname(".match")
    if not matchS then
        return false, "Match service not available"
    end
    
    return skynet.send(matchS, "lua", "leave_room", _player_id)
end

function on_mahjong_ready(_player_id, _msg)
    if not _msg.room_id then
        log.error("Invalid ready format")
        return false, "Invalid message format"
    end
    
    local matchS = skynet.localname(".match")
    if not matchS then
        return false, "Match service not available"
    end
    
    return skynet.send(matchS, "lua", "ready", _player_id)
end

function on_mahjong_play_tile(_player_id, _msg)
    if not _msg.room_id or not _msg.tile_type or not _msg.tile_value then
        log.error("Invalid play tile format")
        return false, "Invalid message format"
    end
    
    local matchS = skynet.localname(".match")
    if not matchS then
        return false, "Match service not available"
    end
    
    return skynet.send(matchS, "lua", "play_tile", _msg.room_id, _player_id, {
        type = _msg.tile_type,
        value = _msg.tile_value
    })
end

function on_mahjong_chi_tile(_player_id, _msg)
    if not _msg.room_id or not _msg.tiles then
        log.error("Invalid chi tile format")
        return false, "Invalid message format"
    end
    
    local matchS = skynet.localname(".match")
    if not matchS then
        return false, "Match service not available"
    end
    
    return skynet.send(matchS, "lua", "chi_tile", _msg.room_id, _player_id, _msg.tiles)
end

function on_mahjong_peng_tile(_player_id, _msg)
    if not _msg.room_id then
        log.error("Invalid peng tile format")
        return false, "Invalid message format"
    end
    
    local matchS = skynet.localname(".match")
    if not matchS then
        return false, "Match service not available"
    end
    
    return skynet.send(matchS, "lua", "peng_tile", _msg.room_id, _player_id)
end

function on_mahjong_gang_tile(_player_id, _msg)
    if not _msg.room_id or not _msg.tile_type or not _msg.tile_value then
        log.error("Invalid gang tile format")
        return false, "Invalid message format"
    end
    
    local matchS = skynet.localname(".match")
    if not matchS then
        return false, "Match service not available"
    end
    
    return skynet.send(matchS, "lua", "gang_tile", _msg.room_id, _player_id, {
        type = _msg.tile_type,
        value = _msg.tile_value
    })
end

function on_mahjong_hu_tile(_player_id, _msg)
    if not _msg.room_id then
        log.error("Invalid hu tile format")
        return false, "Invalid message format"
    end
    
    local matchS = skynet.localname(".match")
    if not matchS then
        return false, "Match service not available"
    end
    
    return skynet.send(matchS, "lua", "hu_tile", _msg.room_id, _player_id)
end

-- 斗地主相关消息处理
function on_landlord_create_room(_player_id, _msg)
    local matchS = skynet.localname(".match")
    if not matchS then
        return false, "Match service not available"
    end
    
    return skynet.send(matchS, "lua", "create_room", _player_id, 1)  -- 1表示斗地主游戏
end

function on_landlord_join_room(_player_id, _msg)
    if not _msg.room_id then
        log.error("Invalid join room format")
        return false, "Invalid message format"
    end
    
    local matchS = skynet.localname(".match")
    if not matchS then
        return false, "Match service not available"
    end
    
    return skynet.send(matchS, "lua", "join_room", _player_id, _msg.room_id)
end

function on_landlord_leave_room(_player_id, _msg)
    local matchS = skynet.localname(".match")
    if not matchS then
        return false, "Match service not available"
    end
    
    return skynet.send(matchS, "lua", "leave_room", _player_id)
end

function on_landlord_ready(_player_id, _msg)
    local matchS = skynet.localname(".match")
    if not matchS then
        return false, "Match service not available"
    end
    
    return skynet.send(matchS, "lua", "ready", _player_id)
end

function on_landlord_play_cards(_player_id, _msg)
    if not _msg.cards then
        log.error("Invalid play cards format")
        return false, "Invalid message format"
    end
    
    local matchS = skynet.localname(".match")
    if not matchS then
        return false, "Match service not available"
    end
    
    return skynet.send(matchS, "lua", "play_cards", _player_id, _msg.cards)
end

function on_landlord_quick_match(_player_id, _msg)
    local matchS = skynet.localname(".match")
    if not matchS then
        return false, "Match service not available"
    end
    
    return skynet.send(matchS, "lua", "quick_match", _player_id, 1)  -- 1表示斗地主游戏
end

function on_landlord_cancel_match(_player_id, _msg)
    local matchS = skynet.localname(".match")
    if not matchS then
        return false, "Match service not available"
    end
    
    return skynet.send(matchS, "lua", "cancel_match", _player_id)
end

-- 处理创建公会请求
function on_create_guild(_player_id, _msg)
    if not _msg.name or not _msg.notice then
        log.error("Invalid create guild format")
        return false, "Invalid message format"
    end
    
    local guildS = skynet.localname(".guild")
    if not guildS then
        return false, "Guild service not available"
    end
    
    skynet.send(guildS, "lua", "create_guild", _player_id, _msg.name, _msg.notice)
    return true
end

-- 处理解散公会请求
function on_disband_guild(_player_id, _msg)
    local guildS = skynet.localname(".guild")
    if not guildS then
        return false, "Guild service not available"
    end
    
    skynet.send(guildS, "lua", "disband_guild", _player_id)
    return true
end

-- 处理加入公会请求
function on_join_guild(_player_id, _msg)
    if not _msg.guild_id then
        log.error("Invalid join guild format")
        return false, "Invalid message format"
    end
    
    local guildS = skynet.localname(".guild")
    if not guildS then
        return false, "Guild service not available"
    end
    
    skynet.send(guildS, "lua", "join_guild", _player_id, _msg.guild_id, _msg.message)
    return true
end

-- 处理退出公会请求
function on_quit_guild(_player_id, _msg)
    local guildS = skynet.localname(".guild")
    if not guildS then
        return false, "Guild service not available"
    end
    
    skynet.send(guildS, "lua", "quit_guild", _player_id)
    return true
end

-- 处理踢出成员请求
function on_kick_member(_player_id, _msg)
    if not _msg.target_id then
        log.error("Invalid kick member format")
        return false, "Invalid message format"
    end
    
    local guildS = skynet.localname(".guild")
    if not guildS then
        return false, "Guild service not available"
    end
    
    skynet.send(guildS, "lua", "kick_member", _player_id, _msg.target_id)
    return true
end

-- 处理任命职位请求
function on_appoint_position(_player_id, _msg)
    if not _msg.target_id or not _msg.position then
        log.error("Invalid appoint position format")
        return false, "Invalid message format"
    end
    
    local guildS = skynet.localname(".guild")
    if not guildS then
        return false, "Guild service not available"
    end
    
    skynet.send(guildS, "lua", "appoint_position", _player_id, _msg.target_id, _msg.position)
    return true
end

-- 处理修改公告请求
function on_modify_notice(_player_id, _msg)
    if not _msg.notice then
        log.error("Invalid modify notice format")
        return false, "Invalid message format"
    end
    
    local guildS = skynet.localname(".guild")
    if not guildS then
        return false, "Guild service not available"
    end
    
    skynet.send(guildS, "lua", "modify_notice", _player_id, _msg.notice)
    return true
end

-- 处理修改加入设置请求
function on_modify_join_setting(_player_id, _msg)
    if _msg.need_approval == nil or not _msg.min_level or not _msg.min_power then
        log.error("Invalid modify join setting format")
        return false, "Invalid message format"
    end
    
    local guildS = skynet.localname(".guild")
    if not guildS then
        return false, "Guild service not available"
    end
    
    skynet.send(guildS, "lua", "modify_join_setting", _player_id, _msg)
    return
end

-- 处理申请处理请求
function on_handle_application(_player_id, _msg)
    if not _msg.target_id or _msg.accept == nil then
        log.error("Invalid handle application format")
        return false, "Invalid message format"
    end
    
    local guildS = skynet.localname(".guild")
    if not guildS then
        return false, "Guild service not available"
    end
    
    skynet.send(guildS, "lua", "handle_application", _player_id, _msg.target_id, _msg.accept)
    return true
end

-- 处理获取公会信息请求
function on_get_guild_info(_player_id, _msg)
    local guildS = skynet.localname(".guild")
    if not guildS then
        return false, "Guild service not available"
    end
    
    skynet.send(guildS, "lua", "get_guild_info", _player_id)
    return true
end

-- 处理获取公会列表请求
function on_get_guild_list(_player_id, _msg)
    local page = _msg.page or 1
    local page_size = _msg.page_size or 10
    
    local guildS = skynet.localname(".guild")
    if not guildS then
        return false, "Guild service not available"
    end
    
    skynet.send(guildS, "lua", "get_guild_list", page, page_size)
    return true
end

-- 处理获取申请列表请求
function on_get_application_list(_player_id, _msg)
    local guildS = skynet.localname(".guild")
    if not guildS then
        return false, "Guild service not available"
    end
    
    skynet.send(guildS, "lua", "get_application_list", _player_id)
    return true
end

-- 邮件相关消息处理
function on_get_mail_list(_player_id, _msg)
    local mailS = skynet.localname(".mail")
    if not mailS then
        return false, "Mail service not available"
    end
    return skynet.call(mailS, "lua", "get_mail_list", _player_id, _msg.page, _msg.page_size)
end

function on_get_mail_detail(_player_id, _msg)
    local mailS = skynet.localname(".mail")
    if not mailS then
        return false, "Mail service not available"
    end
    return skynet.call(mailS, "lua", "get_mail_detail", _player_id, _msg.mail_id)
end

function on_claim_items(_player_id, _msg)
    local mailS = skynet.localname(".mail")
    if not mailS then
        return false, "Mail service not available"
    end
    return skynet.call(mailS, "lua", "claim_items", _player_id, _msg.mail_id)
end

function on_delete_mail(_player_id, _msg)
    local mailS = skynet.localname(".mail")
    if not mailS then
        return false, "Mail service not available"
    end
    return skynet.call(mailS, "lua", "delete_mail", _player_id, _msg.mail_id)
end

function on_send_player_mail(_player_id, _msg)
    local mailS = skynet.localname(".mail")
    if not mailS then
        return false, "Mail service not available"
    end
    return skynet.call(mailS, "lua", "send_player_mail", _player_id, _msg.receiver_id, _msg.title, _msg.content, _msg.items)
end

function on_mark_mail_read(_player_id, _msg)
    local mailS = skynet.localname(".mail")
    if not mailS then
        return false, "Mail service not available"
    end
    return skynet.call(mailS, "lua", "mark_mail_read", _player_id, _msg.mail_id)
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
    -- 好友系统消息处理
    ["add_friend"] = on_add_friend,
    ["delete_friend"] = on_delete_friend,
    ["agree_apply"] = on_agree_apply,
    ["reject_apply"] = on_reject_apply,
    ["get_friend_list"] = on_get_friend_list,
    ["get_apply_list"] = on_get_apply_list,
    ["add_blacklist"] = on_add_blacklist,
    ["remove_blacklist"] = on_remove_blacklist,
    ["get_black_list"] = on_get_black_list,
    -- 麻将相关消息处理
    ["mahjong_create_room"] = on_mahjong_create_room,
    ["mahjong_join_room"] = on_mahjong_join_room,
    ["mahjong_leave_room"] = on_mahjong_leave_room,
    ["mahjong_ready"] = on_mahjong_ready,
    ["mahjong_play_tile"] = on_mahjong_play_tile,
    ["mahjong_chi_tile"] = on_mahjong_chi_tile,
    ["mahjong_peng_tile"] = on_mahjong_peng_tile,
    ["mahjong_gang_tile"] = on_mahjong_gang_tile,
    ["mahjong_hu_tile"] = on_mahjong_hu_tile,
    -- 斗地主相关消息处理
    ["landlord_create_room"] = on_landlord_create_room,
    ["landlord_join_room"] = on_landlord_join_room,
    ["landlord_leave_room"] = on_landlord_leave_room,
    ["landlord_ready"] = on_landlord_ready,
    ["landlord_play_cards"] = on_landlord_play_cards,
    ["landlord_quick_match"] = on_landlord_quick_match,
    ["landlord_cancel_match"] = on_landlord_cancel_match,
    -- 公会相关消息处理
    ["create_guild"] = on_create_guild,
    ["disband_guild"] = on_disband_guild,
    ["join_guild"] = on_join_guild,
    ["quit_guild"] = on_quit_guild,
    ["kick_member"] = on_kick_member,
    ["appoint_position"] = on_appoint_position,
    ["modify_notice"] = on_modify_notice,
    ["modify_join_setting"] = on_modify_join_setting,
    ["handle_application"] = on_handle_application,
    ["get_guild_info"] = on_get_guild_info,
    ["get_guild_list"] = on_get_guild_list,
    ["get_application_list"] = on_get_application_list,
    ["get_mail_list"] = on_get_mail_list,
    ["get_mail_detail"] = on_get_mail_detail,
    ["claim_items"] = on_claim_items,
    ["delete_mail"] = on_delete_mail,
    ["send_player_mail"] = on_send_player_mail,
    ["mark_mail_read"] = on_mark_mail_read,
}

return handle