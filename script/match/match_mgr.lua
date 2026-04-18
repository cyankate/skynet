local skynet = require "skynet"
local match_mgr = {}
local default_match_rules = require "match.match_rules"

--[[
匹配管理器（通用流程层）

职责：
1) 管理匹配队列（matching 阶段）；
2) 管理待确认队伍（pending_confirm 阶段）；
3) 提供确认/拒绝/超时状态流转；
4) 提供规则注册与参数归一化（规则来源：match_rules.lua）。

状态流转（按玩家视角）：
idle -> matching -> pending_confirm -> idle

说明：
- 全员确认后的“最终落地动作”（进副本、进特殊界面等）不在本模块执行，
  由 service/matchS.lua 通过玩法适配器处理。

对外接口：
- start_match(player_id, options)
- cancel_match(player_id)
- confirm_match(player_id, accept)
- poll_expired_pending_matches()
- register_match_rule(type_name, rule)
- shutdown()
]]

match_mgr.match_queues = {} -- queue_key -> { players = {}, options = {} }
match_mgr.player_match_map = {} -- player_id -> queue_key
match_mgr.pending_matches = {} -- match_id -> { players, options, confirms, expire_at }
match_mgr.player_pending_match = {} -- player_id -> match_id
match_mgr.next_match_id = 0
match_mgr.confirm_timeout_sec = 20
match_mgr.match_rules = default_match_rules

function match_mgr.init()
    -- 当前为内存队列，无需额外初始化
end

local function now_sec()
    return math.floor(skynet.time())
end

local function build_match_id()
    match_mgr.next_match_id = match_mgr.next_match_id + 1
    return string.format("m%d", match_mgr.next_match_id)
end

local function release_pending_match(match_id)
    local pending = match_mgr.pending_matches[match_id]
    if not pending then
        return nil
    end
    match_mgr.pending_matches[match_id] = nil
    for _, pid in ipairs(pending.players or {}) do
        if match_mgr.player_pending_match[pid] == match_id then
            match_mgr.player_pending_match[pid] = nil
        end
    end
    return pending
end

local function count_confirmed(pending)
    local confirmed_count = 0
    for _, pid in ipairs(pending.players or {}) do
        if pending.confirms and pending.confirms[pid] then
            confirmed_count = confirmed_count + 1
        end
    end
    return confirmed_count
end

local function create_pending_match(players, options)
    local match_id = build_match_id()
    local expire_at = now_sec() + match_mgr.confirm_timeout_sec
    local pending = {
        match_id = match_id,
        players = players,
        options = options,
        confirms = {},
        create_at = now_sec(),
        expire_at = expire_at,
    }
    for _, pid in ipairs(players or {}) do
        pending.confirms[pid] = false
        match_mgr.player_pending_match[pid] = match_id
    end
    match_mgr.pending_matches[match_id] = pending
    return pending
end

function match_mgr.register_match_rule(type_name, rule)
    if not type_name or type_name == "" then
        return false, "玩法类型不能为空"
    end
    if type(rule) ~= "table" then
        return false, "玩法规则格式错误"
    end
    local entry = tostring(rule.entry or "match")
    if entry ~= "match" and entry ~= "direct" then
        return false, "玩法规则 entry 仅支持 match/direct"
    end
    local max_team_size = tonumber(rule.max_team_size)
    if not max_team_size or max_team_size < 1 then
        return false, "玩法规则缺少有效的 max_team_size"
    end
    match_mgr.match_rules[type_name] = {
        entry = entry,
        max_team_size = max_team_size,
    }
    return true
end

local function build_queue_key(type_name, team_size)
    return string.format(
        "%s:%d",
        tostring(type_name or "multi"),
        tonumber(team_size) or 3
    )
end

local function normalize_options(options)
    options = options or {}
    local type_name = options.type_name or "multi"
    local rule = match_mgr.match_rules[type_name]
    if not rule then
        return nil, string.format("不支持的玩法类型: %s", tostring(type_name))
    end
    local entry = tostring(rule.entry or "match")
    if entry ~= "match" then
        return nil, string.format("玩法[%s]不支持匹配入口", tostring(type_name))
    end

    local team_size = tonumber(rule.max_team_size)
    if not team_size or team_size < 1 then
        return nil, string.format("玩法[%s]缺少有效 max_team_size", tostring(type_name))
    end

    return {
        entry = entry,
        type_name = type_name,
        team_size = team_size,
    }
end

local function try_match_queue(queue_data)
    local team_size = queue_data.options.team_size
    if #queue_data.players < team_size then
        return nil
    end

    local matched_players = {}
    for i = 1, team_size do
        table.insert(matched_players, table.remove(queue_data.players, 1))
    end
    return matched_players
end

local function pop_matched_groups(queue_data)
    local groups = {}
    while true do
        local matched_players = try_match_queue(queue_data)
        if not matched_players then
            break
        end
        for _, pid in ipairs(matched_players) do
            match_mgr.player_match_map[pid] = nil
        end
        table.insert(groups, matched_players)
    end
    return groups
end

local function requeue_players(options, players)
    local normalized_options, normalize_err = normalize_options(options)
    if not normalized_options then
        return false, normalize_err or "匹配参数非法", {}
    end

    local queue_key = build_queue_key(normalized_options.type_name, normalized_options.team_size)
    local queue_data = match_mgr.match_queues[queue_key]
    if not queue_data then
        queue_data = {
            players = {},
            options = normalized_options,
        }
        match_mgr.match_queues[queue_key] = queue_data
    end

    for _, pid in ipairs(players or {}) do
        if not match_mgr.player_match_map[pid] and not match_mgr.player_pending_match[pid] then
            table.insert(queue_data.players, pid)
            match_mgr.player_match_map[pid] = queue_key
        end
    end

    local matched_groups = pop_matched_groups(queue_data)
    if #queue_data.players == 0 then
        match_mgr.match_queues[queue_key] = nil
    end

    local requeued_pending_matches = {}
    for _, group_players in ipairs(matched_groups) do
        local pending = create_pending_match(group_players, queue_data.options)
        table.insert(requeued_pending_matches, pending)
    end
    return true, nil, requeued_pending_matches
end

function match_mgr.start_match(player_id, options)
    if match_mgr.player_match_map[player_id] then
        return false, "玩家已在匹配队列中", nil
    end
    if match_mgr.player_pending_match[player_id] then
        return false, "玩家已在匹配确认阶段", nil
    end

    local normalized_options, normalize_err = normalize_options(options)
    if not normalized_options then
        return false, normalize_err or "匹配参数非法", nil
    end
    local type_name = normalized_options.type_name
    local team_size = normalized_options.team_size

    local queue_key = build_queue_key(
        type_name,
        team_size
    )
    local queue_data = match_mgr.match_queues[queue_key]
    if not queue_data then
        queue_data = {
            players = {},
            options = normalized_options,
        }
        match_mgr.match_queues[queue_key] = queue_data
    end

    table.insert(queue_data.players, player_id)
    match_mgr.player_match_map[player_id] = queue_key

    local matched_players = try_match_queue(queue_data)
    if not matched_players then
        return true, "匹配中", {
            matched = false,
            queue_size = #queue_data.players,
            team_size = queue_data.options.team_size,
        }
    end

    for _, pid in ipairs(matched_players) do
        match_mgr.player_match_map[pid] = nil
    end

    if #queue_data.players == 0 then
        match_mgr.match_queues[queue_key] = nil
    end

    local pending = create_pending_match(matched_players, queue_data.options)

    return true, "匹配成功，等待确认", {
        matched = true,
        pending_confirm = true,
        match_id = pending.match_id,
        pending_match = pending,
        players = matched_players, -- 兼容旧调用方
        options = queue_data.options, -- 兼容旧调用方
        confirm_deadline = pending.expire_at,
    }
end

function match_mgr.cancel_match(player_id)
    local pending_match_id = match_mgr.player_pending_match[player_id]
    if pending_match_id then
        local pending = release_pending_match(pending_match_id)
        if not pending then
            return false, "匹配确认队伍不存在"
        end
        return true, "已取消匹配确认", {
            cancelled_confirm = true,
            match_id = pending_match_id,
            players = pending.players,
            options = pending.options,
        }
    end

    local queue_key = match_mgr.player_match_map[player_id]
    if not queue_key then
        return false, "玩家不在匹配队列中"
    end

    local queue_data = match_mgr.match_queues[queue_key]
    if not queue_data then
        match_mgr.player_match_map[player_id] = nil
        return false, "匹配队列不存在"
    end

    for i, pid in ipairs(queue_data.players) do
        if pid == player_id then
            table.remove(queue_data.players, i)
            break
        end
    end
    match_mgr.player_match_map[player_id] = nil

    if #queue_data.players == 0 then
        match_mgr.match_queues[queue_key] = nil
    end
    return true
end

function match_mgr.confirm_match(player_id, accept)
    local match_id = match_mgr.player_pending_match[player_id]
    if not match_id then
        return false, "玩家不在匹配确认阶段"
    end

    local pending = match_mgr.pending_matches[match_id]
    if not pending then
        match_mgr.player_pending_match[player_id] = nil
        return false, "匹配确认队伍不存在"
    end

    if accept == false then
        local released = release_pending_match(match_id)
        local requeue_players_list = {}
        for _, pid in ipairs(released.players or {}) do
            if pid ~= player_id then
                table.insert(requeue_players_list, pid)
            end
        end

        local requeue_ok, requeue_err, requeued_pending_matches = requeue_players(released.options or {}, requeue_players_list)
        return true, {
            event = "confirm_rejected",
            rejected_player_id = player_id,
            affected_players = released.players or {},
            rejected_match = released,
            requeue_ok = requeue_ok ~= false,
            requeue_error = requeue_err,
            requeued_pending_matches = requeued_pending_matches or {},
        }
    end

    pending.confirms[player_id] = true
    local confirmed_count = count_confirmed(pending)
    local all_confirmed = (confirmed_count >= #pending.players)
    if not all_confirmed then
        return true, {
            event = "confirm_progress",
            pending_match = pending,
        }
    end

    local released = release_pending_match(match_id)
    return true, {
        event = "confirm_all_accepted",
        confirmed_match = released,
    }
end

function match_mgr.poll_expired_pending_matches()
    local now = now_sec()
    local expired = {}
    for match_id, pending in pairs(match_mgr.pending_matches) do
        if now >= (pending.expire_at or 0) then
            local released = release_pending_match(match_id)
            if released then
                table.insert(expired, {
                    timed_out_match = released,
                })
            end
        end
    end
    return expired
end

function match_mgr.shutdown()
    match_mgr.match_queues = {}
    match_mgr.player_match_map = {}
    match_mgr.pending_matches = {}
    match_mgr.player_pending_match = {}
end

return match_mgr
