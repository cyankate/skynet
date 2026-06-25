local skynet = require "skynet"
local user_mgr = require "user_mgr"
local protocol_handler = require "protocol_handler"
local play_rules = require "match.play_rules"
local instance_play_mgr = require "system.instance_play_mgr"

local function on_instance_enter(player_id, msg)
    if not msg.inst_id then
        protocol_handler.send_to_player(player_id, "instance_enter_response", {
            result = 1,
            message = "参数错误",
        })
        return false, "Invalid message format"
    end
    local instanceS = skynet.localname(".instance")
    if not instanceS then
        protocol_handler.send_to_player(player_id, "instance_enter_response", {
            result = 1,
            message = "副本服务不可用",
        })
        return false, "Instance service not available"
    end
    local ok, err = skynet.call(instanceS, "lua", "enter_instance", msg.inst_id, player_id)
    if not ok then
        protocol_handler.send_to_player(player_id, "instance_enter_response", {
            result = 1,
            message = err or "进入失败",
            inst_id = msg.inst_id,
            scene_id = 0,
        })
        return false, err
    end
    local info_ok, info = skynet.call(instanceS, "lua", "get_instance_info", msg.inst_id)
    protocol_handler.send_to_player(player_id, "instance_enter_response", {
        result = 0,
        message = "进入成功",
        inst_id = msg.inst_id,
        scene_id = (info_ok and type(info) == "table" and info.scene_id) or 0,
    })
    return true
end

local function on_instance_exit(player_id, msg)
    if not msg.inst_id then
        protocol_handler.send_to_player(player_id, "instance_exit_response", {
            result = 1,
            message = "参数错误",
        })
        return false, "Invalid message format"
    end
    local instanceS = skynet.localname(".instance")
    if not instanceS then
        protocol_handler.send_to_player(player_id, "instance_exit_response", {
            result = 1,
            message = "副本服务不可用",
        })
        return false, "Instance service not available"
    end
    local ok, err = skynet.call(instanceS, "lua", "exit_instance", msg.inst_id, player_id)
    if not ok then
        protocol_handler.send_to_player(player_id, "instance_exit_response", {
            result = 1,
            message = err or "暂离失败",
            inst_id = msg.inst_id,
        })
        return false, err
    end
    protocol_handler.send_to_player(player_id, "instance_exit_response", {
        result = 0,
        message = "暂离成功",
        inst_id = msg.inst_id,
    })
    return true
end

local function on_instance_quit(player_id, msg)
    if not msg.inst_id then
        protocol_handler.send_to_player(player_id, "instance_quit_response", {
            result = 1,
            message = "参数错误",
        })
        return false, "Invalid message format"
    end
    local instanceS = skynet.localname(".instance")
    if not instanceS then
        protocol_handler.send_to_player(player_id, "instance_quit_response", {
            result = 1,
            message = "副本服务不可用",
        })
        return false, "Instance service not available"
    end
    local ok, err = skynet.call(instanceS, "lua", "quit_instance", msg.inst_id, player_id)
    if not ok then
        protocol_handler.send_to_player(player_id, "instance_quit_response", {
            result = 1,
            message = err or "退出失败",
            inst_id = msg.inst_id,
        })
        return false, err
    end
    protocol_handler.send_to_player(player_id, "instance_quit_response", {
        result = 0,
        message = "退出成功",
        inst_id = msg.inst_id,
    })
    return true
end

local function on_instance_ready(player_id, msg)
    if not msg.inst_id then
        protocol_handler.send_to_player(player_id, "instance_ready_response", {
            result = 1,
            message = "参数错误",
        })
        return false, "Invalid message format"
    end
    local instanceS = skynet.localname(".instance")
    if not instanceS then
        protocol_handler.send_to_player(player_id, "instance_ready_response", {
            result = 1,
            message = "副本服务不可用",
            inst_id = msg.inst_id,
        })
        return false, "Instance service not available"
    end
    local ok, ready_result = skynet.call(instanceS, "lua", "ready_instance", msg.inst_id, player_id)
    if not ok then
        protocol_handler.send_to_player(player_id, "instance_ready_response", {
            result = 1,
            message = ready_result or "准备失败",
            inst_id = msg.inst_id,
        })
        return false, ready_result
    end
    protocol_handler.send_to_player(player_id, "instance_ready_response", {
        result = 0,
        message = ready_result or "准备成功",
        inst_id = msg.inst_id,
    })
    return true
end

local function on_instance_mode_event(player_id, msg)
    if not msg.inst_id or not msg.event_type then
        protocol_handler.send_to_player(player_id, "instance_mode_event_response", {
            result = 1,
            message = "参数错误",
            inst_id = msg.inst_id or "",
            event_type = msg.event_type or "",
        })
        return false, "Invalid message format"
    end
    local instanceS = skynet.localname(".instance")
    if not instanceS then
        protocol_handler.send_to_player(player_id, "instance_mode_event_response", {
            result = 1,
            message = "副本服务不可用",
            inst_id = msg.inst_id,
            event_type = msg.event_type,
        })
        return false, "Instance service not available"
    end
    local ok, err = skynet.call(instanceS, "lua", "instance_mode_event", msg.inst_id, player_id, msg.event_type, {
        event_value = tonumber(msg.event_value) or 0,
        target_id = tonumber(msg.target_id) or 0,
    })
    if not ok then
        protocol_handler.send_to_player(player_id, "instance_mode_event_response", {
            result = 1,
            message = err or "模式事件执行失败",
            inst_id = msg.inst_id,
            event_type = msg.event_type,
        })
        return false, err
    end
    protocol_handler.send_to_player(player_id, "instance_mode_event_response", {
        result = 0,
        message = "模式事件已受理",
        inst_id = msg.inst_id,
        event_type = msg.event_type,
    })
    return true
end

local function on_instance_match_confirm(player_id, msg)
    local matchS = skynet.localname(".match")
    if not matchS then
        return false, "Match service not available"
    end
    skynet.send(matchS, "lua", "confirm_match", player_id, msg.accept ~= false)
    return true
end

local function on_instance_play_start(player_id, msg)
    local type_name = msg.type_name or "single"
    local rule = play_rules[type_name]
    if not rule then
        protocol_handler.send_to_player(player_id, "instance_play_start_response", {
            result = 1,
            message = "不支持的玩法类型",
            mode = "",
            matched = false,
            pending_confirm = false,
            inst_id = "",
            scene_id = 0,
            inst_no = 0,
            extra = "",
        })
        return false, "Unsupported type_name"
    end
    local entry = rule.entry or "match"
    if entry == "direct" then
        local player = user_mgr.get_player_obj(player_id)
        if not player then
            protocol_handler.send_to_player(player_id, "instance_play_start_response", {
                result = 1,
                message = "Player not found",
                mode = "direct",
                matched = false,
                pending_confirm = false,
                inst_id = "",
                scene_id = 0,
                inst_no = 0,
                extra = "",
            })
            return false, "Player not found"
        end
        local ok, result_or_err = instance_play_mgr.play_start(player, type_name, msg.extra)
        if not ok then
            protocol_handler.send_to_player(player_id, "instance_play_start_response", {
                result = 1,
                message = result_or_err or "进入副本失败",
                mode = "direct",
                matched = false,
                pending_confirm = false,
                inst_id = "",
                scene_id = 0,
                inst_no = 0,
                extra = "",
            })
            return false, result_or_err
        end
        protocol_handler.send_to_player(player_id, "instance_play_start_response", {
            result = 0,
            message = "进入副本成功",
            mode = "direct",
            inst_id = result_or_err.inst_id or "",
            scene_id = result_or_err.scene_id or 0,
            inst_no = result_or_err.inst_no or 0,
            extra = "",
            matched = true,
            pending_confirm = false,
        })
        return true
    end
    local matchS = skynet.localname(".match")
    if not matchS then
        return false, "Match service not available"
    end
    skynet.send(matchS, "lua", "start_match", player_id, {
        type_name = type_name,
        extra = msg.extra,
    })
    return true
end

local function on_instance_match_cancel(player_id, msg)
    local matchS = skynet.localname(".match")
    if not matchS then
        return false, "Match service not available"
    end
    skynet.send(matchS, "lua", "cancel_match", player_id)
    return true
end

return {
    instance_enter = on_instance_enter,
    instance_exit = on_instance_exit,
    instance_quit = on_instance_quit,
    instance_ready = on_instance_ready,
    instance_mode_event = on_instance_mode_event,
    instance_play_start = on_instance_play_start,
    instance_match_confirm = on_instance_match_confirm,
    instance_match_cancel = on_instance_match_cancel,
}
