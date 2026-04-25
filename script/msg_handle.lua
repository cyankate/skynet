local skynet = require "skynet"
local log = require "log"
local tableUtils = require "utils.tableUtils"
local user_mgr = require "user_mgr"
local protocol_handler = require "protocol_handler"
local match_rules = require "match.match_rules"
local instance_rules = require "match.instance_rules"
local tilent_mgr = require "system.tilent.tilent_mgr"
local item_mgr = require "system.item_mgr"

function on_add_item(_player_id, _msg)
    local player = user_mgr.get_player_obj(_player_id)
    if not player then
        return false, "Player not found"
    end

    local ok, result_or_err = item_mgr.add_items(player, {
        [_msg.item_id] = _msg.count,
    }, "c2s_add_item")

    if not ok then
        protocol_handler.send_to_player(_player_id, "add_item_response", {
            result = 1,
            message = result_or_err or "add failed",
            changes = {},
        })
        return false, result_or_err
    end

    protocol_handler.send_to_player(_player_id, "add_item_response", {
        result = 0,
        message = "ok",
        changes = result_or_err,
    })
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
    
    local channels = skynet.send(chatS, "lua", "get_channel_list", _player_id)
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

local function send_instance_result(player_id, protocol_name, result, message, payload)
    local data = {
        result = result and 0 or 1,
        message = message or (result and "ok" or "failed"),
    }
    if payload then
        for k, v in pairs(payload) do
            data[k] = v
        end
    end
    protocol_handler.send_to_player(player_id, protocol_name, data)
end

function on_instance_enter(_player_id, _msg)
    if not _msg.inst_id then
        send_instance_result(_player_id, "instance_enter_response", false, "参数错误")
        return false, "Invalid message format"
    end

    local instanceS = skynet.localname(".instance")
    if not instanceS then
        send_instance_result(_player_id, "instance_enter_response", false, "副本服务不可用")
        return false, "Instance service not available"
    end

    local ok, err = skynet.call(instanceS, "lua", "enter_instance", _msg.inst_id, _player_id)
    if not ok then
        send_instance_result(_player_id, "instance_enter_response", false, err or "进入失败", {
            inst_id = _msg.inst_id,
            scene_id = 0,
        })
        return false, err
    end

    local info_ok, info = skynet.call(instanceS, "lua", "get_instance_info", _msg.inst_id)
    send_instance_result(_player_id, "instance_enter_response", true, "进入成功", {
        inst_id = _msg.inst_id,
        scene_id = (info_ok and type(info) == "table" and info.scene_id) or 0,
    })
    return true
end

function on_instance_exit(_player_id, _msg)
    if not _msg.inst_id then
        send_instance_result(_player_id, "instance_exit_response", false, "参数错误")
        return false, "Invalid message format"
    end

    local instanceS = skynet.localname(".instance")
    if not instanceS then
        send_instance_result(_player_id, "instance_exit_response", false, "副本服务不可用")
        return false, "Instance service not available"
    end

    local ok, err = skynet.call(instanceS, "lua", "exit_instance", _msg.inst_id, _player_id)
    if not ok then
        send_instance_result(_player_id, "instance_exit_response", false, err or "暂离失败", {
            inst_id = _msg.inst_id,
        })
        return false, err
    end

    send_instance_result(_player_id, "instance_exit_response", true, "暂离成功", {
        inst_id = _msg.inst_id,
    })
    return true
end

function on_instance_quit(_player_id, _msg)
    if not _msg.inst_id then
        send_instance_result(_player_id, "instance_quit_response", false, "参数错误")
        return false, "Invalid message format"
    end

    local instanceS = skynet.localname(".instance")
    if not instanceS then
        send_instance_result(_player_id, "instance_quit_response", false, "副本服务不可用")
        return false, "Instance service not available"
    end

    local ok, err = skynet.call(instanceS, "lua", "quit_instance", _msg.inst_id, _player_id)
    if not ok then
        send_instance_result(_player_id, "instance_quit_response", false, err or "退出失败", {
            inst_id = _msg.inst_id,
        })
        return false, err
    end

    send_instance_result(_player_id, "instance_quit_response", true, "退出成功", {
        inst_id = _msg.inst_id,
    })
    return true
end

function on_instance_ready(_player_id, _msg)
    if not _msg.inst_id then
        send_instance_result(_player_id, "instance_ready_response", false, "参数错误")
        return false, "Invalid message format"
    end

    local instanceS = skynet.localname(".instance")
    if not instanceS then
        send_instance_result(_player_id, "instance_ready_response", false, "副本服务不可用", {
            inst_id = _msg.inst_id,
        })
        return false, "Instance service not available"
    end

    local ok, ready_result = skynet.call(instanceS, "lua", "ready_instance", _msg.inst_id, _player_id)
    if not ok then
        send_instance_result(_player_id, "instance_ready_response", false, ready_result or "准备失败", {
            inst_id = _msg.inst_id,
        })
        return false, ready_result
    end

    send_instance_result(_player_id, "instance_ready_response", true, ready_result or "准备成功", {
        inst_id = _msg.inst_id,
    })
    return true
end

function on_instance_mode_event(_player_id, _msg)
    if not _msg.inst_id or not _msg.event_type then
        send_instance_result(_player_id, "instance_mode_event_response", false, "参数错误", {
            inst_id = _msg.inst_id or "",
            event_type = _msg.event_type or "",
        })
        return false, "Invalid message format"
    end

    local instanceS = skynet.localname(".instance")
    if not instanceS then
        send_instance_result(_player_id, "instance_mode_event_response", false, "副本服务不可用", {
            inst_id = _msg.inst_id,
            event_type = _msg.event_type,
        })
        return false, "Instance service not available"
    end

    local ok, err = skynet.call(instanceS, "lua", "instance_mode_event", _msg.inst_id, _player_id, _msg.event_type, {
        event_value = tonumber(_msg.event_value) or 0,
        target_id = tonumber(_msg.target_id) or 0,
    })
    if not ok then
        send_instance_result(_player_id, "instance_mode_event_response", false, err or "模式事件执行失败", {
            inst_id = _msg.inst_id,
            event_type = _msg.event_type,
        })
        return false, err
    end

    send_instance_result(_player_id, "instance_mode_event_response", true, "模式事件已受理", {
        inst_id = _msg.inst_id,
        event_type = _msg.event_type,
    })
    return true
end

function on_instance_match_confirm(_player_id, _msg)
    local matchS = skynet.localname(".match")
    if not matchS then
        return false, "Match service not available"
    end

    skynet.send(matchS, "lua", "confirm_match", _player_id, _msg.accept ~= false)
    return true
end

function on_instance_play_start(_player_id, _msg)
    local type_name = _msg.type_name or "single"
    local match_rule = match_rules[type_name]
    local instance_rule = instance_rules[type_name]
    if not match_rule or not instance_rule then
        send_instance_result(_player_id, "instance_play_start_response", false, "不支持的玩法类型", {
            mode = "",
            matched = false,
            pending_confirm = false,
            inst_id = "",
            scene_id = 0,
        })
        return false, "Unsupported type_name"
    end

    local entry = match_rule.entry or "match"
    if entry == "direct" then
        local instanceS = skynet.localname(".instance")
        if not instanceS then
            send_instance_result(_player_id, "instance_play_start_response", false, "副本服务不可用", {
                mode = "direct",
                matched = false,
                pending_confirm = false,
                inst_id = "",
                scene_id = 0,
            })
            return false, "Instance service not available"
        end

        local create_ok, result_or_err, _err_info = skynet.call(
            instanceS,
            "lua",
            "play_start_direct",
            _player_id,
            type_name,
            {
                instance_type_name = instance_rule.instance_type_name,
                inst_no = instance_rule.default_inst_no,
                ready_mode = instance_rule.ready_mode,
                result_source = instance_rule.result_source,
                mode_type = instance_rule.mode_type,
                mode_config = instance_rule.mode_config,
            }
        )
        if not create_ok then
            send_instance_result(_player_id, "instance_play_start_response", false, result_or_err or "进入副本失败", {
                mode = "direct",
                matched = false,
                pending_confirm = false,
                inst_id = "",
                scene_id = 0,
            })
            return false, result_or_err
        end

        send_instance_result(_player_id, "instance_play_start_response", true, "进入副本成功", {
            mode = "direct",
            inst_id = result_or_err.inst_id or "",
            scene_id = result_or_err.scene_id or 0,
            matched = true,
            pending_confirm = false,
        })
        return true
    end

    local matchS = skynet.localname(".match")
    if not matchS then
        return false, "Match service not available"
    end

    -- 匹配玩法入口只负责触发，不等待匹配阶段结果。
    -- 后续状态通过 instance_match_* notify 推送。
    skynet.send(matchS, "lua", "start_match", _player_id, {
        type_name = type_name,
    })
    return true
end

function on_instance_match_cancel(_player_id, _msg)
    local matchS = skynet.localname(".match")
    if not matchS then
        return false, "Match service not available"
    end

    skynet.send(matchS, "lua", "cancel_match", _player_id)
    return true
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


function on_tilent_activate(_player_id, _msg)
    local player = user_mgr.get_player_obj(_player_id)
    if not player then
        protocol_handler.send_to_player(_player_id, "tilent_activate_response", {
            result = 1,
            message = "Player not found",
            tilent_id = tonumber(_msg.tilent_id) or 0,
            level = 0,
        })
        return false, "Player not found"
    end

    tilent_mgr.init_player(player)
    local ok, result_or_err = tilent_mgr.activate_tilent(player, _msg.tilent_id)
    if not ok then
        protocol_handler.send_to_player(_player_id, "tilent_activate_response", {
            result = 1,
            message = result_or_err or "点亮失败",
            tilent_id = tonumber(_msg.tilent_id) or 0,
            level = 0,
        })
        return false, result_or_err
    end

    protocol_handler.send_to_player(_player_id, "tilent_activate_response", {
        result = 0,
        message = "ok",
        tilent_id = result_or_err.id or (tonumber(_msg.tilent_id) or 0),
        level = result_or_err.level or 1,
    })
    tilent_mgr.sync_to_client(player, "activate")
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
    -- 副本相关消息处理
    ["instance_enter"] = on_instance_enter,
    ["instance_exit"] = on_instance_exit,
    ["instance_quit"] = on_instance_quit,
    ["instance_ready"] = on_instance_ready,
    ["instance_mode_event"] = on_instance_mode_event,
    ["instance_play_start"] = on_instance_play_start,
    ["instance_match_confirm"] = on_instance_match_confirm,
    ["instance_match_cancel"] = on_instance_match_cancel,
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
    ["tilent_activate"] = on_tilent_activate,
}

return handle