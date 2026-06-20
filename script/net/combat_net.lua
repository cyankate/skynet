local skynet = require "skynet"
local user_mgr = require "user_mgr"
local protocol_handler = require "protocol_handler"
local barrier_mgr = require "system.barrier_mgr"

local function on_barrier_enter(player_id, msg)
    local player = user_mgr.get_player_obj(player_id)
    if not player then
        protocol_handler.send_to_player(player_id, "barrier_enter_response", {
            result = 1,
            message = "Player not found",
            barrier_id = tonumber(msg.barrier_id) or 0,
        })
        return false, "Player not found"
    end

    local ok, result_or_err = barrier_mgr.enter_barrier(player, msg.barrier_id)
    if not ok then
        protocol_handler.send_to_player(player_id, "barrier_enter_response", {
            result = 1,
            message = result_or_err or "进入关卡失败",
            barrier_id = tonumber(msg.barrier_id) or 0,
        })
        return false, result_or_err
    end

    protocol_handler.send_to_player(player_id, "barrier_enter_response", {
        result = 0,
        message = "ok",
        barrier_id = result_or_err.barrier_id,
        inst_id = result_or_err.inst_id,
        scene_id = result_or_err.scene_id,
        stamina = result_or_err.stamina,
    })
    return true
end

local function on_barrier_settle(player_id, msg)
    local player = user_mgr.get_player_obj(player_id)
    if not player then
        protocol_handler.send_to_player(player_id, "barrier_settle_response", {
            result = 1,
            message = "Player not found",
        })
        return false, "Player not found"
    end

    local ok, result_or_err = barrier_mgr.settle_barrier(
        player,
        msg.inst_id,
        msg.success,
        msg.stars,
        msg.progress
    )
    if not ok then
        protocol_handler.send_to_player(player_id, "barrier_settle_response", {
            result = 1,
            message = result_or_err or "结算失败",
        })
        return false, result_or_err
    end

    protocol_handler.send_to_player(player_id, "barrier_settle_response", {
        result = 0,
        message = "ok",
        barrier_id = result_or_err.barrier_id,
        success = result_or_err.success,
        stars = result_or_err.stars,
        progress = result_or_err.progress,
        best_stars = result_or_err.best_stars,
        first_pass = result_or_err.first_pass,
    })
    barrier_mgr.sync_to_client(player)
    return true
end

local function on_barrier_claim_chest(player_id, msg)
    local player = user_mgr.get_player_obj(player_id)
    if not player then
        protocol_handler.send_to_player(player_id, "barrier_claim_chest_response", {
            result = 1,
            message = "Player not found",
            barrier_id = tonumber(msg.barrier_id) or 0,
            chest_index = tonumber(msg.chest_index) or 0,
        })
        return false, "Player not found"
    end

    local ok, result_or_err = barrier_mgr.claim_chest(player, msg.barrier_id, msg.chest_index)
    if not ok then
        protocol_handler.send_to_player(player_id, "barrier_claim_chest_response", {
            result = 1,
            message = result_or_err or "领取失败",
            barrier_id = tonumber(msg.barrier_id) or 0,
            chest_index = tonumber(msg.chest_index) or 0,
        })
        return false, result_or_err
    end

    protocol_handler.send_to_player(player_id, "barrier_claim_chest_response", {
        result = 0,
        message = "ok",
        barrier_id = result_or_err.barrier_id,
        chest_index = result_or_err.chest_index,
    })
    barrier_mgr.sync_to_client(player)
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
    local instanceS = skynet.localname(".instance")
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
    local instanceS = skynet.localname(".instance")
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
    local instanceS = skynet.localname(".instance")
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
    barrier_enter = on_barrier_enter,
    barrier_settle = on_barrier_settle,
    barrier_claim_chest = on_barrier_claim_chest,
    rogue_pick_open = on_rogue_pick_open,
    rogue_pick_refresh = on_rogue_pick_refresh,
    rogue_pick_select = on_rogue_pick_select,
}
