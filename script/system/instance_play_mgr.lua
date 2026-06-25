--[[
    统一副本进本 / 结算调度
]]

local skynet = require "skynet"
local play_rules = require "match.play_rules"
local tableUtils = require "utils.tableUtils"
local item_mgr = require "system.item_mgr"

local M = {}

local function num(v)
    return tonumber(v) or 0
end

function M.play_start(player, type_name, extra)
    local rule = play_rules[type_name]
    if not rule then
        return false, "不支持的玩法类型"
    end

    local extra = extra or {}
    local inst_no = num(extra.inst_no)
    if inst_no <= 0 then
        return false, "inst_no无效"
    end

    local player_pack = player:build_instance_pack()
    local ctx = {
        type_name = type_name,
        rule = rule,
        extra = extra,
        player_pack = player_pack,
    }

    local hook_ok, hook_err = play_rules.call_hook(rule, "before_instance_start", player, ctx)
    if hook_ok == nil then
        hook_ok = true
    end
    if hook_ok ~= true then
        return false, hook_err or "进本校验失败"
    end

    local play_options = {
        inst_no = inst_no,
        instance_type_name = rule.instance_type_name,
        ready_mode = rule.ready_mode or "auto",
        mode_type = rule.mode_type,
        mode_config = rule.mode_config,
        join_data = ctx.player_pack,
    }

    local instanceS = skynet.localname(".instance")
    if not instanceS then
        return false, "副本服务不可用"
    end

    local create_ok, result_or_err = skynet.call(instanceS, "lua", "play_start_direct", player.player_id_, type_name, play_options)
    if not create_ok then
        play_rules.call_hook(rule, "on_play_start_failed", player, ctx, result_or_err)
        return false, result_or_err or "进入副本失败"
    end

    player:set_instance_session({
        type_name = type_name,
        inst_no = play_options.inst_no,
        inst_id = result_or_err.inst_id,
        scene_id = result_or_err.scene_id or 0,
        extra = extra,
        enter_time = os.time(),
        settling = false,
    })

    return true, {
        type_name = type_name,
        inst_no = play_options.inst_no,
        inst_id = result_or_err.inst_id,
        scene_id = result_or_err.scene_id or 0,
    }
end

local function give_rewards(player, rewards, reason)
    if type(rewards) ~= "table" or not next(rewards) then
        return true
    end
    return item_mgr.add_items(player, rewards, reason or "instance_settle")
end

function M.on_complete(player, params)
    params = params or {}
    local inst_id = params.inst_id
    if inst_id == nil or inst_id == "" then
        return false, "inst_id无效"
    end
    local success = params.success and true or false
    local complete_data = type(params.complete_data) == "table" and params.complete_data or {}

    local session = player:get_instance_session()
    local type_name = params.type_name
    local inst_no = num(params.inst_no)

    if type(session) == "table" and session.inst_id then
        if session.inst_id ~= inst_id then
            return false, "副本会话无效"
        end
        if session.settling then
            return false, "结算处理中"
        end
        type_name = session.type_name or type_name
        inst_no = num(session.inst_no) > 0 and num(session.inst_no) or inst_no
        session.settling = true
        player:set_instance_session(session)
    end

    type_name = tostring(type_name or "")
    if type_name == "" then
        if type(session) == "table" then
            session.settling = nil
            player:set_instance_session(session)
        end
        return false, "玩法类型未知"
    end

    local rule = play_rules[type_name]
    if not rule then
        if type(session) == "table" then
            session.settling = nil
            player:set_instance_session(session)
        end
        return false, "玩法规则不存在"
    end

    local ctx = {
        type_name = type_name,
        rule = rule,
        extra = type(session) == "table" and (session.extra or {}) or {},
        session = session or {},
        inst_id = inst_id,
        inst_no = inst_no,
        success = success,
        complete_data = complete_data,
    }

    local hook_ok, end_data_or_err = play_rules.call_hook(rule, "before_instance_end", player, ctx)
    if hook_ok == nil then
        hook_ok, end_data_or_err = true, {}
    end
    if hook_ok ~= true then
        if type(session) == "table" then
            session.settling = nil
            player:set_instance_session(session)
        end
        return false, end_data_or_err or "结算校验失败"
    end
    end_data_or_err = end_data_or_err or {}

    local add_ok, add_err = give_rewards(player, end_data_or_err.rewards, end_data_or_err.reward_reason or "instance_settle")
    if not add_ok then
        if type(session) == "table" then
            session.settling = nil
            player:set_instance_session(session)
        end
        return false, add_err or "发放奖励失败"
    end

    play_rules.call_hook(rule, "after_instance_end", player, ctx, end_data_or_err)
    player:clear_instance_session()

    return true, {
        settle_data = end_data_or_err.settle_data or {},
    }
end

return M
