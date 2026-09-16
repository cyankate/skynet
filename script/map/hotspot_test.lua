-- 热点压测：观察者 + 运动实体集中于小区域，持续打满 AOI 可见性/合批/下发链路
-- 与 move_test 分工：move_test 测镜头随机移动的视野 diff；本模块测局部热点广播放大
--
-- 虚拟玩家全部用字符串 id（hobs_/hmarch_/hmon_ 前缀），与真实玩家隔离：
--   - 下发包：gate 查不到 fd 静默丢弃，无错误日志，AOI 扫描/可见性/合批/pack 全链路真实执行
--   - 不建城、不落库、不走 agent 通知（march owner 置 nil 自动跳过）
-- 压测实体只进本片（坐标钳在本片像素矩形内缩进边界，防行军跨片 handoff 泄漏到邻片）
--
-- 用法（debug console）：
--   call .shard.1001.0 "hotspot_start"                          -- 默认参数
--   call .shard.1001.0 "hotspot_start" { observers = 100, marchers = 300 }
--   call .shard.1001.0 "hotspot_stop"
local skynet = require "skynet"
local log = require "log"
local aoi_object = require "map.aoi_object"
local march = require "map.march"
local shard = require "map.shard"
local service_ctx = require "runtime.service_ctx"
local view_sync = require "map.view_sync"

local ctx = service_ctx.get("map.shard_service", {})
local M = {}

local DEFAULTS = {
    radius = 150,          -- 热点半径（view_range=100，保证可见集高度重叠）
    observers = 50,        -- 虚拟观察者数（静止聚焦热点）
    marchers = 100,        -- 虚拟行军数（主要移动负载，热点内往返游走）
    monsters = 40,         -- 热点巡逻怪（patrol_radius > 0，走 monster_ai 通道）
    duration_sec = 120,
    report_interval = 500, -- 报告周期（skynet 单位，500 = 5s）
}

local hs = nil -- 运行态：{ cx, cy, radius, observers, observer_list, marches, monsters, deadline, ... }

-- 热点内随机取点：钳在本片像素矩形内（缩进 10，防贴边触发跨片 handoff / ghost 投影干扰）
local function rand_point(map)
    local x0, y0, x1, y1 = shard.pixel_rect(map.shard_id, map.def)
    local ang = math.random() * math.pi * 2
    local r = math.random() * hs.radius
    local x = math.floor(hs.cx + math.cos(ang) * r)
    local y = math.floor(hs.cy + math.sin(ang) * r)
    return math.max(x0 + 10, math.min(x1 - 10, x)), math.max(y0 + 10, math.min(y1 - 10, y))
end

-- 虚拟观察者：observer 实体进 AOI + 纯视野 player_state，全量同步建立 visible_uids
local function spawn_observer(map, i)
    local pid = string.format("hobs_%d_%d", map.shard_id, i)
    local x, y = rand_point(map)
    local st = {
        player_id = pid,
        player_name = pid,
        current_map_id = map.map_id,
        current_scene_id = map.map_id,
        visible_uids = {},
    }
    ctx.player_state[pid] = st
    local obs = aoi_object.Observer.new({
        uid = pid,
        player_id = pid,
        player_name = pid,
        x = x,
        y = y,
        view_range = ctx.MAP_VIEW_RANGE or 100,
        map_id = map.map_id,
        shard_id = map.shard_id,
        owner_shard_id = map.shard_id,
        is_ghost = false,
    })
    local ok, err = map:enter_obj(obs)
    if not ok then
        ctx.player_state[pid] = nil
        return nil, err
    end
    view_sync.sync_full(pid, map, st)
    hs.observers[pid] = true
    hs.observer_list[#hs.observer_list + 1] = pid
    return pid
end

-- 虚拟行军：热点内两点游走，到达后由 report 周期重新派点。
-- 直接进 ctx.marches 由 march tick 驱动（绕开主城出发/agent 通知等业务前置）
local function spawn_march(map, i)
    local uid = string.format("hmarch_%d_%d", map.shard_id, i)
    local x, y = rand_point(map)
    local tx, ty = rand_point(map)
    local m = march.new({
        uid = uid,
        x = x,
        y = y,
        waypoints = { { x = x, y = y }, { x = tx, y = ty } },
        speed = march.SPEED,
        state = march.STATE_MARCHING,
        map_id = map.map_id,
        shard_id = map.shard_id,
        owner_shard_id = map.shard_id,
        last_path_tx = tx,
        last_path_ty = ty,
    })
    m.owner_player_id = nil -- 无属主：notify_march_sync / remember_owner_march 自动跳过
    march.bind_map(m, map.map_id, map.shard_id)
    m.x, m.y = math.floor(m.x + 0.5), math.floor(m.y + 0.5)
    local ok, err = map:enter_obj(m)
    if not ok then
        return nil, err
    end
    m.in_aoi = true
    ctx.marches[uid] = m
    hs.marches[uid] = true
    return uid
end

-- 热点巡逻怪：进 public_monsters 由 monster_ai 驱动（不进库；被打死会从本表剔除）
local function spawn_monster(map, i)
    local uid = string.format("hmon_%d_%d", map.shard_id, i)
    local x, y = rand_point(map)
    local obj = {
        uid = uid,
        type = aoi_object.TYPE.MONSTER,
        map_id = map.map_id,
        shard_id = map.shard_id,
        owner_shard_id = map.shard_id,
        x = x,
        y = y,
        view_range = 0,
        is_ghost = false,
        alive = true,
        kind = "hotspot",
        owner_player_id = 0,
        patrol_radius = math.random(40, 80),
    }
    map:attach(obj, aoi_object.TYPE.MONSTER)
    map.public_monsters[uid] = obj
    hs.monsters[uid] = true
    return uid
end

-- 给走完路径的行军重新派随机目标，维持持续移动负载
local function repath_arrived(map)
    local n = 0
    for uid in pairs(hs.marches) do
        local m = ctx.marches[uid]
        if m and m.alive and m.state == march.STATE_MARCHING
            and not (m.waypoints and m.waypoints[m.wp_index or 1]) then
            local tx, ty = rand_point(map)
            m.waypoints = { { x = m.x, y = m.y }, { x = tx, y = ty } }
            m.wp_index = 1
            m.last_path_tx, m.last_path_ty = tx, ty
            n = n + 1
        end
    end
    return n
end

-- tick 耗时快照：读取时清零 max，report 拿到的是窗口内峰值
local function snapshot_tick_cost()
    local snap = {}
    for name, s in pairs(ctx.tick_cost or {}) do
        snap[name] = { total = s.total, count = s.count, max = s.max }
        s.max = 0
    end
    return snap
end

-- 窗口内 tick 平均/峰值耗时（单位 0.01s → ms）
local function tick_cost_ms(last_snap, name)
    local cur = ctx.tick_cost and ctx.tick_cost[name]
    if not cur then
        return 0, 0
    end
    local last = last_snap and last_snap[name]
    local dcount = cur.count - (last and last.count or 0)
    local dtotal = cur.total - (last and last.total or 0)
    local avg = dcount > 0 and (dtotal / dcount * 10) or 0
    return avg, (cur.max or 0) * 10
end

local function count_alive(t, pool)
    local n = 0
    for uid in pairs(t) do
        local obj = pool[uid]
        if obj and obj.alive then
            n = n + 1
        end
    end
    return n
end

local function march_alive()
    return count_alive(hs.marches, ctx.marches)
end

local function mon_alive()
    return count_alive(hs.monsters, ctx.map and ctx.map.public_monsters or {})
end

local function report_tick(map)
    if not hs then
        return
    end
    if skynet.now() >= hs.deadline then
        log.info("[hotspot] duration reached, auto stop")
        M.stop()
        return
    end
    repath_arrived(map)
    local s = view_sync.stats_snapshot()
    local last = hs.last_stats
    hs.last_stats = s
    local last_cost = hs.last_tick_cost
    -- 先算窗口耗时（读 cur.max 作为窗口峰值），再拍新快照（清零 max）
    local m_avg, m_max = tick_cost_ms(last_cost, "march")
    local p_avg, p_max = tick_cost_ms(last_cost, "patrol")
    hs.last_tick_cost = snapshot_tick_cost()
    if last then
        local dt = (s.now - last.now) / 100
        if dt > 0 then
            local function rate(key)
                -- 计数可能被 view_sync 启动时的一次性 stats_report 清零，负值按 0 计
                return math.max(0, ((s[key] or 0) - (last[key] or 0)) / dt)
            end
            local sent = rate("delta_sent_count")
            local enter = rate("delta_enter_total")
            local leave = rate("delta_leave_total")
            local update = rate("delta_update_total")
            local entries = enter + leave + update
            log.info(string.format(
                "[hotspot] obs=%d march=%d mon=%d | sent=%.0f/s entries=%.0f/s e/p=%.1f (e=%.0f l=%.0f u=%.0f) | visible_scan=%.0f/s attr=%.0f/s full=%.0f/s diff=%.0f/s | march_tick avg=%.1fms peak=%.1fms | patrol_tick avg=%.1fms peak=%.1fms",
                #hs.observer_list, march_alive(), mon_alive(),
                sent, entries, sent > 0 and (entries / sent) or 0, enter, leave, update,
                rate("sync_obj_visible_count"), rate("sync_obj_attr_count"),
                rate("sync_full_count"), rate("sync_diff_count"),
                m_avg, m_max, p_avg, p_max))
        end
    end
    skynet.timeout(hs.report_interval, function()
        report_tick(map)
    end)
end

function M.start(opts)
    local map = ctx.map
    if not map then
        return false, "map not found"
    end
    if hs then
        return false, "hotspot already running"
    end
    if type(opts) ~= "table" then
        opts = {}
    end
    local o = {}
    for k, v in pairs(DEFAULTS) do
        o[k] = tonumber(opts[k]) or v
    end
    local cx, cy = tonumber(opts.x), tonumber(opts.y)
    if not cx or not cy then
        -- 默认热点中心 = 本片中心
        local x0, y0, x1, y1 = shard.pixel_rect(map.shard_id, map.def)
        cx = cx or math.floor((x0 + x1) / 2)
        cy = cy or math.floor((y0 + y1) / 2)
    end
    math.randomseed(skynet.now() * 131 + (map.shard_id or 0))
    hs = {
        cx = cx,
        cy = cy,
        radius = o.radius,
        observers = {},
        observer_list = {},
        marches = {},
        monsters = {},
        deadline = skynet.now() + o.duration_sec * 100,
        report_interval = o.report_interval,
    }
    local n_obs, n_mon, n_mar = 0, 0, 0
    for i = 1, o.observers do
        if spawn_observer(map, i) then
            n_obs = n_obs + 1
        end
    end
    for i = 1, o.monsters do
        if spawn_monster(map, i) then
            n_mon = n_mon + 1
        end
    end
    for i = 1, o.marchers do
        if spawn_march(map, i) then
            n_mar = n_mar + 1
        end
    end
    hs.last_stats = view_sync.stats_snapshot()
    hs.last_tick_cost = snapshot_tick_cost()
    skynet.timeout(o.report_interval, function()
        report_tick(map)
    end)
    log.info("[hotspot] start: shard=%s center=(%d,%d) r=%d obs=%d marchers=%d monsters=%d duration=%ds",
        tostring(map.shard_id), cx, cy, o.radius, n_obs, n_mar, n_mon, o.duration_sec)
    return true, { observers = n_obs, marchers = n_mar, monsters = n_mon, x = cx, y = cy }
end

function M.stop()
    if not hs then
        return false, "hotspot not running"
    end
    local map = ctx.map
    local n_obs, n_mar, n_mon = 0, 0, 0
    if map then
        for uid in pairs(hs.marches) do
            local m = ctx.marches[uid]
            if m then
                if m.in_aoi then
                    pcall(function()
                        map:leave_obj(uid)
                    end)
                end
                ctx.marches[uid] = nil
                n_mar = n_mar + 1
            end
        end
        for uid in pairs(hs.monsters) do
            local obj = map.public_monsters[uid]
            if obj then
                map:detach(obj)
                map.public_monsters[uid] = nil
                n_mon = n_mon + 1
            end
        end
        for pid in pairs(hs.observers) do
            pcall(function()
                map:leave_obj(pid)
            end)
            ctx.player_state[pid] = nil
            n_obs = n_obs + 1
        end
    end
    log.info("[hotspot] stop: removed obs=%d march=%d mon=%d", n_obs, n_mar, n_mon)
    hs = nil
    return true
end

function M.status()
    if not hs then
        return false, "hotspot not running"
    end
    return true, {
        observers = #hs.observer_list,
        marchers = march_alive(),
        monsters = mon_alive(),
        remain_sec = math.max(0, (hs.deadline - skynet.now()) / 100),
    }
end

return M
