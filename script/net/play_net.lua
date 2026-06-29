--[[
    副本外玩法协议：进本、匹配、关卡进度等（不在副本实例内执行）
]]

local skynet = require "skynet"
local user_mgr = require "user_mgr"
local protocol_handler = require "protocol_handler"
local play_rules = require "match.play_rules"
local instance_play_mgr = require "system.instance_play_mgr"
local barrier_mgr = require "system.barrier_mgr"
local log = require "log"
local tableUtils = require "utils.tableUtils"

local function on_barrier_claim_chest(player_id, msg)
    local player = user_mgr.get_player_obj(player_id)
    if not player then
        protocol_handler.send_to_player(player_id, "barrier_claim_chest_response", {
            result = 1,
            message = "Player not found",
            barrier_no = tonumber(msg.barrier_no) or 0,
            chest_index = tonumber(msg.chest_index) or 0,
        })
        return false, "Player not found"
    end

    local ok, result_or_err = barrier_mgr.claim_chest(player, msg.barrier_no, msg.chest_index)
    if not ok then
        protocol_handler.send_to_player(player_id, "barrier_claim_chest_response", {
            result = 1,
            message = result_or_err or "领取失败",
            barrier_no = tonumber(msg.barrier_no) or 0,
            chest_index = tonumber(msg.chest_index) or 0,
        })
        return false, result_or_err
    end

    protocol_handler.send_to_player(player_id, "barrier_claim_chest_response", {
        result = 0,
        message = "ok",
        barrier_no = result_or_err.barrier_no,
        chest_index = result_or_err.chest_index,
    })
    barrier_mgr.sync_to_client(player)
    return true
end

local function on_instance_play_start(player_id, msg)
    log.error("on_instance_play_start %s %s", player_id, tableUtils.serialize_table(msg))
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

local function on_instance_match_confirm(player_id, msg)
    local matchS = skynet.localname(".match")
    if not matchS then
        return false, "Match service not available"
    end
    skynet.send(matchS, "lua", "confirm_match", player_id, msg.accept ~= false)
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
    barrier_claim_chest = on_barrier_claim_chest,
    instance_play_start = on_instance_play_start,
    instance_match_confirm = on_instance_match_confirm,
    instance_match_cancel = on_instance_match_cancel,
}
