--[[
    副本内协议：进退本、准备、模式事件、局内玩法交互等
]]

local skynet = require "skynet"
local protocol_handler = require "protocol_handler"

local function get_instance_service()
    return skynet.localname(".instance")
end

local function on_instance_enter(player_id, msg)
    if not msg.inst_id then
        protocol_handler.send_to_player(player_id, "instance_enter_response", {
            result = 1,
            message = "参数错误",
        })
        return false, "Invalid message format"
    end
    local instanceS = get_instance_service()
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
    local instanceS = get_instance_service()
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
    local instanceS = get_instance_service()
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
    local instanceS = get_instance_service()
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
    local instanceS = get_instance_service()
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

local function on_rogue_pick_open(player_id, msg)
    if not msg.inst_id then
        protocol_handler.send_to_player(player_id, "rogue_pick_open_response", {
            result = 1,
            message = "参数错误",
            inst_id = "",
        })
        return false, "Invalid message format"
    end
    local instanceS = get_instance_service()
    if not instanceS then
        protocol_handler.send_to_player(player_id, "rogue_pick_open_response", {
            result = 1,
            message = "副本服务不可用",
            inst_id = msg.inst_id,
        })
        return false, "Instance service not available"
    end
    local ok, result_or_err = skynet.call(instanceS, "lua", "rogue_pick_open", msg.inst_id, player_id)
    if not ok then
        protocol_handler.send_to_player(player_id, "rogue_pick_open_response", {
            result = 1,
            message = result_or_err or "开抽失败",
            inst_id = msg.inst_id,
        })
        return false, result_or_err
    end
    protocol_handler.send_to_player(player_id, "rogue_pick_open_response", {
        result = 0,
        message = "ok",
        inst_id = msg.inst_id,
        pick_index = result_or_err.pick_index,
    })
    return true
end

local function on_rogue_pick_refresh(player_id, msg)
    if not msg.inst_id then
        protocol_handler.send_to_player(player_id, "rogue_pick_refresh_response", {
            result = 1,
            message = "参数错误",
            inst_id = msg.inst_id or "",
        })
        return false, "Invalid message format"
    end
    local instanceS = get_instance_service()
    if not instanceS then
        protocol_handler.send_to_player(player_id, "rogue_pick_refresh_response", {
            result = 1,
            message = "副本服务不可用",
            inst_id = msg.inst_id,
        })
        return false, "Instance service not available"
    end
    local ok, result_or_err = skynet.call(instanceS, "lua", "rogue_pick_refresh", msg.inst_id, player_id)
    if not ok then
        protocol_handler.send_to_player(player_id, "rogue_pick_refresh_response", {
            result = 1,
            message = result_or_err or "刷新失败",
            inst_id = msg.inst_id,
        })
        return false, result_or_err
    end
    protocol_handler.send_to_player(player_id, "rogue_pick_refresh_response", {
        result = 0,
        message = "ok",
        inst_id = msg.inst_id,
        pick_index = result_or_err.pick_index,
    })
    return true
end

local function on_rogue_pick_select(player_id, msg)
    if not msg.inst_id or not msg.choice_index then
        protocol_handler.send_to_player(player_id, "rogue_pick_select_response", {
            result = 1,
            message = "参数错误",
            inst_id = msg.inst_id or "",
        })
        return false, "Invalid message format"
    end
    local instanceS = get_instance_service()
    if not instanceS then
        protocol_handler.send_to_player(player_id, "rogue_pick_select_response", {
            result = 1,
            message = "副本服务不可用",
            inst_id = msg.inst_id,
        })
        return false, "Instance service not available"
    end
    local ok, result_or_err = skynet.call(
        instanceS,
        "lua",
        "rogue_pick_select",
        msg.inst_id,
        player_id,
        msg.choice_index
    )
    if not ok then
        protocol_handler.send_to_player(player_id, "rogue_pick_select_response", {
            result = 1,
            message = result_or_err or "选择失败",
            inst_id = msg.inst_id,
        })
        return false, result_or_err
    end
    protocol_handler.send_to_player(player_id, "rogue_pick_select_response", {
        result = 0,
        message = "ok",
        inst_id = msg.inst_id,
        ability_id = result_or_err.ability_id,
        effect_id = result_or_err.effect_id,
        pick_times = result_or_err.pick_times,
    })
    return true
end

return {
    instance_enter = on_instance_enter,
    instance_exit = on_instance_exit,
    instance_quit = on_instance_quit,
    instance_ready = on_instance_ready,
    instance_mode_event = on_instance_mode_event,
    rogue_pick_open = on_rogue_pick_open,
    rogue_pick_refresh = on_rogue_pick_refresh,
    rogue_pick_select = on_rogue_pick_select,
}
