--[[
    统一副本进本 / 结算调度
]]

local skynet = require "skynet"
local BARRIER_DATA = require "setting.BARRIER_DATA"
local instance_rules = require "match.instance_rules"
local tableUtils = require "utils.tableUtils"
local item_mgr = require "system.item_mgr"

local M = {}

local function num(v)
    return tonumber(v) or 0
end

local function parse_extra(extra_raw)
    if type(extra_raw) == "table" then
        return extra_raw
    end
    if type(extra_raw) ~= "string" or extra_raw == "" then
        return {}
    end
    local ok, data = pcall(tableUtils.deserialize_table, extra_raw)
    if ok and type(data) == "table" then
        return data
    end
    return {}
end

local function validate_inst_no(inst_no)
    inst_no = num(inst_no)
    if inst_no <= 0 then
        return false, "inst_no无效"
    end
    if not BARRIER_DATA[inst_no] then
        return false, "副本配置不存在"
    end
    return true, inst_no
end

local function attach_player_pack(play_options, player_pack)
    play_options = play_options or {}
    play_options.join_data = play_options.join_data or {}
    if player_pack and not play_options.join_data.player_pack then
        play_options.join_data.player_pack = player_pack
    end
    return play_options
end

local function default_before_instance_start(player, ctx)
    local inst_no = num((ctx.extra or {}).inst_no)
    if inst_no <= 0 then
        return false, "inst_no无效"
    end
    return true, attach_player_pack({
        inst_no = inst_no,
        join_data = ctx.extra or {},
    }, ctx.player_pack)
end

local function invoke_start_hook(rule, player, ctx)
    local hook_ok, hook_result = instance_rules.call_hook(rule, "before_instance_start", player, ctx)
    if hook_ok == nil then
        return default_before_instance_start(player, ctx)
    end
    return hook_ok, hook_result
end

local function merge_play_options(rule, play_options)
    play_options = play_options or {}
    return {
        inst_no = play_options.inst_no,
        instance_type_name = play_options.instance_type_name or rule.instance_type_name,
        ready_mode = play_options.ready_mode or rule.ready_mode or "auto",
        result_source = play_options.result_source or rule.result_source or "server",
        mode_type = play_options.mode_type or rule.mode_type,
        mode_config = play_options.mode_config or rule.mode_config,
        join_data = play_options.join_data or {},
    }
end

function M.parse_extra(extra_raw)
    return parse_extra(extra_raw)
end

function M.play_start(player, type_name, extra_raw)
    type_name = tostring(type_name or "")
    local rule = instance_rules[type_name]
    if not rule then
        return false, "不支持的玩法类型"
    end

    local extra = parse_extra(extra_raw)
    local player_pack = player:build_instance_pack()
    local ctx = {
        type_name = type_name,
        rule = rule,
        extra = extra,
        player_pack = player_pack,
    }

    local ok, play_options_or_err = invoke_start_hook(rule, player, ctx)
    if ok ~= true then
        return false, play_options_or_err or "进本校验失败"
    end
    if type(play_options_or_err) ~= "table" then
        return false, "handler 返回无效"
    end

    play_options_or_err = attach_player_pack(play_options_or_err, ctx.player_pack)

    local inst_ok, inst_no_or_err = validate_inst_no(play_options_or_err.inst_no)
    if not inst_ok then
        return false, inst_no_or_err
    end

    local play_options = merge_play_options(rule, play_options_or_err)
    play_options.inst_no = inst_no_or_err

    local instanceS = skynet.localname(".instance")
    if not instanceS then
        return false, "副本服务不可用"
    end

    local create_ok, result_or_err = skynet.call(instanceS, "lua", "play_start_direct", player.player_id_, type_name, play_options)
    if not create_ok then
        instance_rules.call_hook(rule, "on_play_start_failed", player, ctx, result_or_err)
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
        start_extra = play_options_or_err.start_extra,
    }
end

local function give_rewards(player, rewards, reason)
    if type(rewards) ~= "table" or not next(rewards) then
        return true
    end
    return item_mgr.add_items(player, rewards, reason or "instance_settle")
end

local function default_before_instance_end(_player, _ctx)
    return true, {}
end

local function invoke_end_hook(rule, player, ctx)
    local hook_ok, hook_result = instance_rules.call_hook(rule, "before_instance_end", player, ctx)
    if hook_ok == nil then
        return default_before_instance_end(player, ctx)
    end
    return hook_ok, hook_result
end

function M.on_complete(player, params)
    params = params or {}
    local inst_id = params.inst_id
    if inst_id == nil or inst_id == "" then
        return false, "inst_id无效"
    end
    local success = params.success and true or false
    -- 副本侧打包的结算数据（玩法结果）
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

    local rule = instance_rules[type_name]
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

    local ok, end_data_or_err = invoke_end_hook(rule, player, ctx)
    if ok ~= true then
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

    instance_rules.call_hook(rule, "after_instance_end", player, ctx, end_data_or_err)
    player:clear_instance_session()

    local settle_data = end_data_or_err.settle_data or {}

    return true, {
        settle_data = settle_data,
    }
end

return M
