--[[
    统一副本进本 / 结算调度
]]

local skynet = require "skynet"
local play_rules = require "match.play_rules"
local item_mgr = require "system.item_mgr"
local BARRIER_DATA = require "setting.BARRIER_DATA"
local INSTANCE_DATA = require "setting.INSTANCE_DATA"

local M = {}

local function num(v)
    return tonumber(v) or 0
end

local function normalize_play_extra(type_name, extra)
    extra = extra or {}
    if type_name == "barrier" then
        local barrier_no = num(extra.barrier_no)
        if barrier_no <= 0 then
            return nil, "关卡参数无效"
        end
        local barrier_cfg = BARRIER_DATA[barrier_no]
        if not barrier_cfg then
            return nil, "关卡配置不存在"
        end
        local inst_no = num(barrier_cfg.InstNo)
        if inst_no <= 0 or not INSTANCE_DATA[inst_no] then
            return nil, "副本配置不存在"
        end
        extra.barrier_no = barrier_no
        extra.inst_no = inst_no
        return extra
    end

    local inst_no = num(extra.inst_no)
    if inst_no <= 0 then
        return nil, "inst_no无效"
    end
    if not INSTANCE_DATA[inst_no] then
        return nil, "副本配置不存在"
    end
    return extra
end

function M.play_start(player, type_name, extra)
    local rule = play_rules[type_name]
    if not rule then
        return false, "不支持的玩法类型"
    end

    local normalized_extra, normalize_err = normalize_play_extra(type_name, extra or {})
    if not normalized_extra then
        return false, normalize_err or "进本参数无效"
    end
    extra = normalized_extra
    local inst_no = num(extra.inst_no)

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

local function build_reward_list(rewards)
    local list = {}
    if type(rewards) ~= "table" then
        return list
    end
    for item_id_raw, count_raw in pairs(rewards) do
        local item_id = num(item_id_raw)
        local count = num(count_raw)
        if item_id > 0 and count > 0 then
            list[#list + 1] = { item_id = item_id, count = count }
        end
    end
    table.sort(list, function(a, b)
        return a.item_id < b.item_id
    end)
    return list
end

function M.on_complete(player, params)
    params = params or {}
    local inst_id = params.inst_id
    if inst_id == nil or inst_id == "" then
        return false, "inst_id无效"
    end
    local success = params.success == true
    local complete_data = params.complete_data or {}

    local session = player:get_instance_session()
    local type_name = params.type_name or ""
    local inst_no = num(params.inst_no)

    if type(session) == "table" and session.inst_id then
        if session.inst_id ~= inst_id then
            return false, "副本会话无效"
        end
        if session.settling then
            return false, "结算处理中"
        end
        session.settling = true
        player:set_instance_session(session)
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

    local hook_ok, end_data_or_err = play_rules.call_hook(rule, "before_instance_settle", player, ctx)
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

    play_rules.call_hook(rule, "on_instance_settled", player, ctx, end_data_or_err)
    player:clear_instance_session()

    return true, {
        settle_data = end_data_or_err.settle_data or {},
        rewards = build_reward_list(end_data_or_err.rewards),
    }
end

function M.on_action(player, params)
    params = params or {}
    local inst_id = params.inst_id
    local action = tostring(params.action or "")
    if inst_id == nil or inst_id == "" or action == "" then
        return false, "副本交互参数无效"
    end

    local session = player:get_instance_session()
    local type_name = tostring(params.type_name or "")
    if type(session) == "table" and session.inst_id then
        if session.inst_id ~= inst_id then
            return false, "副本会话无效"
        end
        if session.settling then
            return false, "结算处理中"
        end
    end

    local rule = play_rules[type_name]
    if not rule then
        return false, "玩法规则不存在"
    end

    local ctx = {
        type_name = type_name,
        rule = rule,
        extra = type(session) == "table" and (session.extra or {}) or {},
        session = session or {},
        inst_id = inst_id,
        inst_no = num(params.inst_no),
        action = action,
        payload = type(params.payload) == "table" and params.payload or {},
    }

    local hook_ok, hook_result = play_rules.call_hook(rule, "on_instance_action", player, ctx)
    if hook_ok == nil then
        return true
    end
    if hook_ok ~= true then
        return false, hook_result or "副本交互被拒绝"
    end
    return true, hook_result
end

return M
