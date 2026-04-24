local skynet = require "skynet"
local log = require "log"
local service_wrapper = require "utils.service_wrapper"
local match_mgr = require "match.match_mgr"
local match_mode_adapter_mgr = require "match.match_mode_adapter_mgr"
local instance_rules = require "match.instance_rules"
local protocol_handler = require "protocol_handler"
local EXPIRE_POLL_TICK = 100 -- 1s

local function pending_players(pending)
    local players = {}
    for _, pid in ipairs((pending and pending.players) or {}) do
        table.insert(players, pid)
    end
    return players
end

local function notify_confirm_state(players, pending)
    local data = pending or {}
    local members = data.members
    if not members then
        members = {}
        for _, pid in ipairs(data.players or {}) do
            table.insert(members, {
                player_id = pid,
                confirmed = data.confirms and data.confirms[pid] == true or false,
            })
        end
    end
    local payload = {
        type_name = ((data.options or {}).type_name) or "",
        match_id = data.match_id or "",
        members = members,
        confirm_deadline = data.expire_at or data.confirm_deadline or 0,
    }
    for _, pid in ipairs(players or {}) do
        protocol_handler.send_to_player(pid, "instance_match_confirm_notify", payload)
    end
end

local function notify_match_tip(players, type_name, message)
    for _, pid in ipairs(players or {}) do
        protocol_handler.send_to_player(pid, "instance_match_tip_notify", {
            type_name = type_name or "",
            message = message or "",
        })
    end
end

local function notify_queue_state(player_id, type_name, queue_size, team_size)
    protocol_handler.send_to_player(player_id, "instance_match_queue_notify", {
        type_name = type_name or "",
        queue_size = tonumber(queue_size) or 0,
        team_size = tonumber(team_size) or 0,
    })
end

local function clear_confirm_state(players)
    local members = {}
    for _, pid in ipairs(players or {}) do
        table.insert(members, {
            player_id = pid,
            confirmed = false,
        })
    end
    if #members == 0 then
        table.insert(members, {
            player_id = 0,
            confirmed = false,
        })
    end
    notify_confirm_state(players, {
        match_id = "cleared",
        options = {
            type_name = "none",
        },
        confirm_deadline = 0,
        players = players or {},
        confirms = {},
        members = members,
    })
end

local function pending_type_name(pending)
    return ((pending or {}).options or {}).type_name or ""
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
        mode_type = inst_rule.mode_type,
        mode_config = inst_rule.mode_config,
    }
end

local function drain_expired_pending_matches()
    local instanceS = skynet.localname(".instance")
    local expired_matches = match_mgr.poll_expired_pending_matches()
    for _, item in ipairs(expired_matches or {}) do
        local timed_out_match = item.timed_out_match or {}
        local players = pending_players(timed_out_match)
        if instanceS then
            skynet.send(instanceS, "lua", "clear_match_flow", players)
        end
        clear_confirm_state(players)
        notify_match_tip(players, pending_type_name(timed_out_match), "匹配确认超时，队伍已解散")
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
        local err = "副本服务不可用"
        notify_match_tip({ player_id }, (options and options.type_name) or "", err)
        return false, err
    end

    local in_instance = skynet.call(instanceS, "lua", "get_player_instance", player_id)
    if in_instance then
        local err = "玩家已在副本中"
        notify_match_tip({ player_id }, (options and options.type_name) or "", err)
        return false, err
    end

    local flow_ok, flow_err = skynet.call(instanceS, "lua", "try_enter_match_flow", player_id)
    if not flow_ok then
        notify_match_tip({ player_id }, (options and options.type_name) or "", flow_err or "玩家当前状态不可匹配")
        return false, flow_err or "玩家当前状态不可匹配"
    end

    local ok, msg, result = match_mgr.start_match(player_id, options)
    if not ok then
        local err = msg or "开始匹配失败"
        skynet.send(instanceS, "lua", "clear_match_flow", { player_id })
        notify_match_tip({ player_id }, (options and options.type_name) or "", err)
        return false, err
    end

    if not result or not result.matched then
        local queue_size = (result and result.queue_size) or 0
        local team_size = (result and result.team_size) or 0
        local type_name = (options and options.type_name) or ""
        notify_queue_state(player_id, type_name, queue_size, team_size)
        notify_match_tip({ player_id }, type_name, string.format("匹配中 (%d/%d)", queue_size, team_size))
        return true, msg or "匹配中"
    end

    local matched_players = result.players or {}
    local match_options, build_err = build_instance_options(result.options or {})
    if not match_options then
        skynet.send(instanceS, "lua", "clear_match_flow", matched_players)
        for _, pid in ipairs(matched_players) do
            notify_match_tip({ pid }, ((result.options or {}).type_name) or "", tostring(build_err or "副本规则缺失，匹配已取消"))
        end
        return false, build_err or "副本规则缺失，匹配已取消"
    end

    local prepare_ok, _profiles_or_err = match_mode_adapter_mgr.prepare_team(matched_players, match_options)
    if not prepare_ok then
        skynet.send(instanceS, "lua", "clear_match_flow", matched_players)
        for _, pid in ipairs(matched_players) do
            notify_match_tip({ pid }, match_options.type_name or "", tostring(_profiles_or_err or "队伍校验失败，匹配已取消"))
        end
        return false, _profiles_or_err or "队伍校验失败，匹配已取消"
    end
    local pending_match = result.pending_match or {}
    skynet.send(instanceS, "lua", "mark_pending_confirm", matched_players)
    notify_confirm_state(matched_players, pending_match)
    notify_match_tip(matched_players, pending_type_name(pending_match), "匹配成功，请确认")

    return true, "匹配成功，请确认"
end

function CMD.confirm_match(player_id, accept)
    local instanceS = skynet.localname(".instance")
    local ok, result_or_err = match_mgr.confirm_match(player_id, accept)
    if not ok then
        notify_match_tip({player_id}, "", tostring(result_or_err or "确认匹配失败"))
        return
    end
    local result = result_or_err or {}
    local event = result.event or ""

    if event == "confirm_rejected" then
        local affected_players = result.affected_players or {}
        skynet.send(instanceS, "lua", "clear_match_flow", affected_players)
        clear_confirm_state(affected_players)
        if result.requeue_ok == false then
            notify_match_tip(affected_players, pending_type_name(result.rejected_match), "有玩家拒绝确认，重新匹配失败: " .. tostring(result.requeue_error or "未知错误"))
            return
        end
        notify_match_tip(affected_players, pending_type_name(result.rejected_match), "有玩家拒绝确认，重新匹配")
        skynet.send(instanceS, "lua", "clear_match_flow", { result.rejected_player_id })
        for _, rematch in ipairs(result.requeued_pending_matches or {}) do
            local rematch_players = pending_players(rematch)
            skynet.send(instanceS, "lua", "mark_pending_confirm", rematch_players)
            notify_confirm_state(rematch_players, rematch)
        end
        return

    elseif event == "confirm_progress" then
        local pending_match = result.pending_match or {}
        local players = pending_players(pending_match)
        notify_confirm_state(players, pending_match)
        return
    elseif event == "confirm_all_accepted" then
        local confirmed_match = result.confirmed_match or {}
        local players = pending_players(confirmed_match)
        local match_options, build_err = build_instance_options(confirmed_match.options or {})
        if not match_options then
            skynet.send(instanceS, "lua", "clear_match_flow", players)
            clear_confirm_state(players)
            notify_match_tip(players, pending_type_name(confirmed_match), tostring(build_err or "副本规则缺失，匹配已取消"))
            return
        end

        local create_ok, batch_result_or_err, stage = match_mode_adapter_mgr.on_all_confirmed(players, match_options)
        if not create_ok then
            skynet.send(instanceS, "lua", "clear_match_flow", players)
            clear_confirm_state(players)
            notify_match_tip(players, match_options.type_name or "", "全员确认后创建副本失败(" .. tostring(stage) .. "): " .. tostring(batch_result_or_err or "未知错误"))
            local requeue_ok, requeue_err, requeued_pending_matches = match_mgr.requeue_matched_group(confirmed_match.options or {}, players)
            if not requeue_ok then
                notify_match_tip(players, match_options.type_name or "", "补偿重排队失败: " .. tostring(requeue_err or "未知错误"))
                return
            end
            notify_match_tip(players, match_options.type_name or "", "已自动重排队，请重新确认")
            for _, rematch in ipairs(requeued_pending_matches or {}) do
                local rematch_players = pending_players(rematch)
                if instanceS then
                    skynet.send(instanceS, "lua", "mark_pending_confirm", rematch_players)
                end
                notify_confirm_state(rematch_players, rematch)
            end
            return
        end

        local inst_id = batch_result_or_err.inst_id
        for _, pid in ipairs(players) do
            protocol_handler.send_to_player(pid, "instance_match_success_notify", {
                type_name = match_options.type_name or "",
                inst_id = inst_id,
                team_size = match_options.team_size or #players,
            })
        end
        clear_confirm_state(players)
        notify_match_tip(players, match_options.type_name or "", "全员确认完成，进入副本")
        return
    else
        return
    end
end
 
function CMD.cancel_match(player_id)
    local instanceS = skynet.localname(".instance")
    local ok, msg_or_err, data = match_mgr.cancel_match(player_id)
    if not ok then
        notify_match_tip({ player_id }, "", msg_or_err or "取消匹配失败")
        return
    end

    if data and data.cancelled_confirm then
        if instanceS then
            skynet.send(instanceS, "lua", "clear_match_flow", data.players or {})
        end
        clear_confirm_state(data.players)
        notify_match_tip(data.players, pending_type_name(data), "有玩家取消确认，队伍已解散")
    elseif instanceS then
        skynet.send(instanceS, "lua", "clear_match_flow", { player_id })
    end
    notify_match_tip({ player_id }, ((data and data.options) and data.options.type_name) or "", "取消匹配成功")
end

local function main()
    CMD.init()
end

service_wrapper.create_service(main, {
    name = "match",
})
