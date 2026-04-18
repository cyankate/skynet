local skynet = require "skynet"
local log = require "log"
local service_wrapper = require "utils.service_wrapper"
local match_mgr = require "match.match_mgr"
local match_mode_adapter_mgr = require "match.match_mode_adapter_mgr"
local instance_rules = require "match.instance_rules"
local protocol_handler = require "protocol_handler"
local EXPIRE_POLL_TICK = 100 -- 1s

local function build_confirm_members(players, confirms)
    local members = {}
    for _, pid in ipairs(players or {}) do
        table.insert(members, {
            player_id = pid,
            confirmed = confirms and confirms[pid] == true or false,
        })
    end
    return members
end

local function pending_to_confirm_snapshot(pending)
    local data = pending or {}
    return {
        match_id = data.match_id or "",
        members = build_confirm_members(data.players or {}, data.confirms or {}),
        confirm_deadline = data.expire_at or data.confirm_deadline or 0,
    }
end

local function pending_players(pending)
    local players = {}
    for _, pid in ipairs((pending and pending.players) or {}) do
        table.insert(players, pid)
    end
    return players
end

local function notify_confirm_state(players, match_snapshot)
    local snapshot = match_snapshot or {}
    local payload = {
        match_id = snapshot.match_id or "",
        members = snapshot.members or {},
        confirm_deadline = snapshot.confirm_deadline or 0,
    }
    for _, pid in ipairs(players or {}) do
        protocol_handler.send_to_player(pid, "instance_match_confirm_notify", payload)
    end
end

local function notify_match_tip(players, message)
    for _, pid in ipairs(players or {}) do
        protocol_handler.send_to_player(pid, "instance_match_tip_notify", {
            message = message or "",
        })
    end
end

local function clear_confirm_state(players)
    notify_confirm_state(players, {
        match_id = "",
        members = {},
        confirm_deadline = 0,
    })
end

local function build_instance_options(match_options)
    local opt = match_options or {}
    local type_name = opt.type_name or ""
    local inst_rule = instance_rules[type_name]
    if not inst_rule then
        return nil, string.format("玩法[%s]缺少副本规则", tostring(type_name))
    end
    local team_size = tonumber(opt.team_size) or 0
    if team_size < 1 then
        return nil, string.format("玩法[%s]队伍人数非法", tostring(type_name))
    end

    return {
        type_name = type_name,
        entry = opt.entry or "match",
        team_size = team_size,
        min_players = team_size,
        max_players = team_size,
        instance_type_name = inst_rule.instance_type_name,
        adapter_name = inst_rule.adapter_name or "instance_default",
        result_source = inst_rule.result_source or "server",
        ready_mode = inst_rule.ready_mode,
        inst_no = tonumber(inst_rule.default_inst_no) or 0,
    }
end

local function drain_expired_pending_matches()
    local expired_matches = match_mgr.poll_expired_pending_matches()
    for _, item in ipairs(expired_matches or {}) do
        local timed_out_match = item.timed_out_match or {}
        local players = pending_players(timed_out_match)
        clear_confirm_state(players)
        notify_match_tip(players, "匹配确认超时，队伍已解散")
    end
end

local function update_loop()
    while true do
        drain_expired_pending_matches()
        skynet.sleep(EXPIRE_POLL_TICK)
    end
end

-- 初始化
function CMD.init()
    log.info("match service init")
    match_mgr.init()
    skynet.fork(update_loop)
end

-- 副本随机匹配入口
function CMD.start_match(player_id, options)
    local instanceS = skynet.localname(".instance")
    if not instanceS then
        notify_match_tip({ player_id }, "副本服务不可用")
        return
    end
    local in_instance = skynet.call(instanceS, "lua", "get_player_instance", player_id)
    if in_instance then
        notify_match_tip({ player_id }, "玩家已在副本中")
        return
    end

    local ok, msg, result = match_mgr.start_match(player_id, options)
    if not ok then
        notify_match_tip({ player_id }, msg or "开始匹配失败")
        return
    end

    if not result or not result.matched then
        return
    end

    local matched_players = result.players or {}
    local match_options, build_err = build_instance_options(result.options or {})
    if not match_options then
        for _, pid in ipairs(matched_players) do
            protocol_handler.send_to_player(pid, "error", {
                code = 5204,
                message = tostring(build_err or "副本规则缺失，匹配已取消"),
            })
            notify_match_tip({ pid }, tostring(build_err or "副本规则缺失，匹配已取消"))
        end
        return
    end

    local prepare_ok, _profiles_or_err = match_mode_adapter_mgr.prepare_team(matched_players, match_options)
    if not prepare_ok then
        for _, pid in ipairs(matched_players) do
            protocol_handler.send_to_player(pid, "error", {
                code = 5203,
                message = tostring(_profiles_or_err or "队伍校验失败，匹配已取消"),
            })
            notify_match_tip({ pid }, tostring(_profiles_or_err or "队伍校验失败，匹配已取消"))
        end
        return
    end
    local pending_match = result.pending_match or {}
    local pending_snapshot = pending_to_confirm_snapshot(pending_match)
    notify_confirm_state(matched_players, pending_snapshot)
    notify_match_tip(matched_players, "匹配成功，请确认")

    return
end

function CMD.confirm_match(player_id, accept)
    local ok, result_or_err = match_mgr.confirm_match(player_id, accept)
    if not ok then
        notify_match_tip({player_id}, tostring(result_or_err or "确认匹配失败"))
        return
    end
    local result = result_or_err or {}
    local event = result.event or ""

    if event == "confirm_rejected" then
        local affected_players = result.affected_players or {}
        clear_confirm_state(affected_players)
        if result.requeue_ok == false then
            notify_match_tip(affected_players, "有玩家拒绝确认，重新匹配失败: " .. tostring(result.requeue_error or "未知错误"))
            return
        end
        notify_match_tip(affected_players, "有玩家拒绝确认，重新匹配")
        for _, rematch in ipairs(result.requeued_pending_matches or {}) do
            local rematch_players = pending_players(rematch)
            local rematch_snapshot = pending_to_confirm_snapshot(rematch)
            notify_confirm_state(rematch_players, rematch_snapshot)
        end
        return

    elseif event == "confirm_progress" then
        local pending_match = result.pending_match or {}
        local players = pending_players(pending_match)
        local pending_snapshot = pending_to_confirm_snapshot(pending_match)
        notify_confirm_state(players, pending_snapshot)
        return
    elseif event == "confirm_all_accepted" then
        local confirmed_match = result.confirmed_match or {}
        local players = pending_players(confirmed_match)
        local match_options, build_err = build_instance_options(confirmed_match.options or {})
        if not match_options then
            clear_confirm_state(players)
            notify_match_tip(players, tostring(build_err or "副本规则缺失，匹配已取消"))
            return
        end

        local create_ok, batch_result_or_err, stage = match_mode_adapter_mgr.on_all_confirmed(players, match_options)
        if not create_ok then
            clear_confirm_state(players)
            notify_match_tip(players, "全员确认后创建副本失败(" .. tostring(stage) .. "): " .. tostring(batch_result_or_err or "未知错误"))
            return
        end

        local inst_id = batch_result_or_err.inst_id
        for _, pid in ipairs(players) do
            protocol_handler.send_to_player(pid, "instance_match_success_notify", {
                inst_id = inst_id,
                team_size = match_options.team_size or #players,
            })
        end
        clear_confirm_state(players)
        notify_match_tip(players, "全员确认完成，进入副本")
        return
    else
        return
    end
end

function CMD.cancel_match(player_id)
    local ok, msg_or_err, data = match_mgr.cancel_match(player_id)
    if not ok then
        notify_match_tip({ player_id }, msg_or_err or "取消匹配失败")
        return
    end

    if data and data.cancelled_confirm then
        clear_confirm_state(data.players)
        notify_match_tip(data.players, "有玩家取消确认，队伍已解散")
    end
    notify_match_tip({ player_id }, "取消匹配成功")
end

local function main()
    CMD.init()
end

service_wrapper.create_service(main, {
    name = "match",
})
