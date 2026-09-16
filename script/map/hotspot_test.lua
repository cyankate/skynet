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
--   call .shard.1001.0 "hotspot_start" { x = 1024, y = 1024 }   -- 边界热点（churn 会真实跨片迁移）
--   call .shard.1001.0 "hotspot_start" { battlers = 0 }       -- 关掉交战，只测行军游走
--   call .shard.1001.0 "hotspot_start" { churners = 0 }         -- 关掉 churn，与静态基线对比
--   call .shard.1001.0 "hotspot_stop"
local skynet = require "skynet"
local log = require "log"
local aoi_object = require "map.aoi_object"
local march = require "map.march"
local march_runtime = require "map.march_runtime"
local march_battle = require "map.march_battle"
local shard = require "map.shard"
local service_ctx = require "runtime.service_ctx"
local view_sync = require "map.view_sync"
local observer = require "map.observer"

local ctx = service_ctx.get("map.shard_service", {})
local M = {}

local DEFAULTS = {
    radius = 150,          -- 热点半径（view_range=100，保证可见集高度重叠）
    observers = 50,        -- 虚拟观察者数（静止聚焦热点）
    churners = 10,         -- 移动观察者数（热点内持续游走，打 enter/leave churn 与跨片迁移路径；0=关闭）
    marchers = 100,        -- 虚拟行军数（主要移动负载，热点内往返游走）
    battlers = 40,         -- 其中配对开战数（偶数；到点冻结 + 定时结算）。0=关闭；超出 marchers 时钳到 marchers
    monsters = 40,         -- 热点巡逻怪（patrol_radius > 0，走 monster_ai 通道）
    duration_sec = 120,
    report_interval = 500, -- 报告周期（skynet 单位，500 = 5s）
}

-- churn 移动参数：300ms 一步、每步 40 单位 ≈ 133 单位/秒的镜头拖扫。
-- AOI 网格 50，单步跨格概率 ~80%，稳定触发视野 diff + enter/leave
local CHURN_TICK = 30
local CHURN_STEP = 40

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
        hotspot_virtual = true, -- 隔离 move_test 接力（跨片时随 snap 接力），见 move_test.start
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
    return pid, x, y
end

-- churn 目标点：以热点中心随机取点，只钳地图边界、不钳本片——
-- 边界热点场景下目标会落到邻片，走真实 transfer_observer 迁移路径
local function churn_target(map)
    local ang = math.random() * math.pi * 2
    local r = math.random() * hs.radius
    local x = math.floor(hs.cx + math.cos(ang) * r)
    local y = math.floor(hs.cy + math.sin(ang) * r)
    return math.max(1, math.min(map.def.width, x)), math.max(1, math.min(map.def.height, y))
end

-- 单个 churner 推进一步。位置/归属片由本地账本维护（每步必更新），跨片走 CMD.move 远程路由
local function step_churner(map, pid, c)
    if not c.tx then
        c.tx, c.ty = churn_target(map)
    end
    local dx, dy = c.tx - c.x, c.ty - c.y
    local dist = math.sqrt(dx * dx + dy * dy)
    local nx, ny
    if dist <= CHURN_STEP then
        nx, ny = c.tx, c.ty
        c.tx, c.ty = nil, nil -- 到位，下一步重派目标
    else
        nx = math.floor(c.x + dx / dist * CHURN_STEP)
        ny = math.floor(c.y + dy / dist * CHURN_STEP)
    end
    local mv_ok, mv_err
    if c.shard == map.shard_id then
        mv_ok, mv_err = observer.move(pid, nx, ny)
    else
        -- 已迁移到邻片：远程调 owner 片的 move（observer.move 读的是目标 VM 的 player_state）
        local pok, r_ok, r_err = pcall(skynet.call, shard.addr(map.map_id, c.shard), "lua", "move", pid, nx, ny)
        if pok then
            mv_ok, mv_err = r_ok, r_err
        else
            mv_ok, mv_err = false, tostring(r_ok)
        end
    end
    if not hs then
        return -- 远程调用让出协程，回来可能已 stop
    end
    if mv_ok then
        c.errs = 0
        c.x, c.y = nx, ny
        hs.w_moves = hs.w_moves + 1
        local ns = shard.shard_id_of_pos(nx, ny, map.def)
        if ns ~= c.shard then
            c.shard = ns
            hs.w_transfers = hs.w_transfers + 1
        end
    else
        hs.w_move_errs = hs.w_move_errs + 1
        -- 前 10 次、之后每 50 次打一次失败原因+现场，避免刷屏（排障关键：原因不能被计数器吞掉）
        if hs.w_move_errs <= 10 or hs.w_move_errs % 50 == 0 then
            local ent = map:get_obj(pid)
            local st = ctx.player_state[pid]
            log.info("[hotspot] churn move fail: pid=%s ledger_shard=%s pos=(%s,%s)->(%s,%s) ent=%s st=%s scene=%s reason=%s",
                pid, tostring(c.shard), tostring(c.x), tostring(c.y), tostring(nx), tostring(ny),
                tostring(ent ~= nil), tostring(st ~= nil),
                tostring(st and st.current_scene_id), tostring(mv_err))
        end
        c.tx = nil -- 失败重派目标
        c.errs = (c.errs or 0) + 1
        if c.errs > 20 then
            -- 持续失败（状态被清/服务异常）：移出 churn 列表，观察者留到 stop 统一清
            log.info("[hotspot] churn drop: pid=%s after %d consecutive errors", pid, c.errs)
            hs.churn[pid] = nil
        end
    end
end

local function churn_tick(map)
    if not hs then
        return
    end
    skynet.timeout(CHURN_TICK, function()
        churn_tick(map)
    end)
    for pid, c in pairs(hs.churn) do
        pcall(step_churner, map, pid, c)
        if not hs then
            return
        end
    end
end

-- 虚拟行军：热点内两点游走，到达后由 report 周期重新派点。
-- 直接进 ctx.marches 由 march tick 驱动（绕开主城出发/agent 通知等业务前置）
-- pos: 可选 { x, y, hold, hp, max_hp }；hold=true 时终点=起点，给交战对原地冻结
local function spawn_march(map, i, pos)
    local uid = string.format("hmarch_%d_%d", map.shard_id, i)
    local x, y
    if pos and pos.x and pos.y then
        x, y = pos.x, pos.y
    else
        x, y = rand_point(map)
    end
    local tx, ty
    if pos and pos.hold then
        tx, ty = x, y
    else
        tx, ty = rand_point(map)
    end
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
        hp = pos and pos.hp,
        max_hp = pos and pos.max_hp,
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
        hp = 100,
        max_hp = 100,
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
            and not (hs.battlers and hs.battlers[uid])
            and not (m.waypoints and m.waypoints[m.wp_index or 1]) then
            local tx, ty = rand_point(map)
            m.waypoints = { { x = m.x, y = m.y }, { x = tx, y = ty } }
            m.wp_index = 1
            m.last_path_tx, m.last_path_ty = tx, ty
            march_runtime.broadcast_plan(map, m) -- 心跳推算：repath = 计划变更广播
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

local function n_battles()
    local n = 0
    for _ in pairs(ctx.field_battles or {}) do
        n = n + 1
    end
    return n
end

-- 交战对若提前结束，每轮报告补一次 engage（开战/结算各推一次属性，不再 tick 扣血）
local function maintain_battles()
    if not hs or not hs.battler_pairs then
        return
    end
    for _, p in ipairs(hs.battler_pairs) do
        local a, b = ctx.marches[p[1]], ctx.marches[p[2]]
        if a and b and a.alive and b.alive and not a.battle_id and not b.battle_id then
            a.hp = a.max_hp or a.hp
            b.hp = b.max_hp or b.hp
            march_battle.engage(p[1], p[2])
        end
    end
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
    maintain_battles()
    local s = view_sync.stats_snapshot()
    local last = hs.last_stats
    hs.last_stats = s
    local last_cost = hs.last_tick_cost
    -- 先算窗口耗时（读 cur.max 作为窗口峰值），再拍新快照（清零 max）
    local m_avg, m_max = tick_cost_ms(last_cost, "march")
    local p_avg, p_max = tick_cost_ms(last_cost, "patrol")
    hs.last_tick_cost = snapshot_tick_cost()
    -- churn 窗口计数取出即清零（与报告周期对齐，与 view_sync stats 的 reset 互不干扰）
    local w_moves, w_transfers, w_move_errs = hs.w_moves, hs.w_transfers, hs.w_move_errs
    hs.w_moves, hs.w_transfers, hs.w_move_errs = 0, 0, 0
    local n_churn = 0
    for _ in pairs(hs.churn) do
        n_churn = n_churn + 1
    end
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
            -- 压测粗估带宽（偏保守：enter 按行军全量字段）；生产发包不走这条估算
            local bytes = enter * 140 + leave * 12 + update * 30 + sent * 40
            local itemsmax = s.delta_pkt_items_max or 0
            log.info(string.format(
                "[hotspot] obs=%d churn=%d march=%d battle=%d mon=%d | sent=%.0f/s entries=%.0f/s e/p=%.1f (e=%.0f l=%.0f u=%.0f) bytes≈%.1fKB/s pkt≈%.0fB itemsmax=%d | visible_scan=%.0f/s attr=%.0f/s full=%.0f/s diff=%.0f/s | churn mv=%.0f/s xfer=%d err=%d | march_tick avg=%.1fms peak=%.1fms | patrol_tick avg=%.1fms peak=%.1fms",
                #hs.observer_list, n_churn, march_alive(), n_battles(), mon_alive(),
                sent, entries, sent > 0 and (entries / sent) or 0, enter, leave, update,
                bytes / 1024, sent > 0 and (bytes / sent) or 0, itemsmax,
                rate("sync_obj_visible_count"), rate("sync_obj_attr_count"),
                rate("sync_full_count"), rate("sync_diff_count"),
                w_moves / dt, w_transfers, w_move_errs,
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
        churn = {},          -- pid => { x, y, shard, tx, ty, errs } 移动观察者账本
        marches = {},
        battlers = {},       -- uid => true，交战行军（repath 跳过）
        battler_pairs = {},  -- { {atk, def}, ... }
        monsters = {},
        deadline = skynet.now() + o.duration_sec * 100,
        report_interval = o.report_interval,
        w_moves = 0,         -- 窗口计数：churn 移动步数（report 后清零）
        w_transfers = 0,     -- 窗口计数：跨片迁移次数
        w_move_errs = 0,     -- 窗口计数：churn 移动失败次数
    }
    local n_obs, n_mon, n_mar, n_churn, n_bat = 0, 0, 0, 0, 0
    for i = 1, o.observers do
        if spawn_observer(map, i) then
            n_obs = n_obs + 1
        end
    end
    for i = 1, o.churners do
        local pid, x, y = spawn_observer(map, o.observers + i)
        if pid then
            hs.churn[pid] = { x = x, y = y, shard = map.shard_id }
            n_churn = n_churn + 1
        end
    end
    for i = 1, o.monsters do
        if spawn_monster(map, i) then
            n_mon = n_mon + 1
        end
    end
    local n_pair = math.floor((o.battlers or 0) / 2)
    local max_pair = math.floor(o.marchers / 2)
    if n_pair > max_pair then
        n_pair = max_pair
    end
    -- hp=10000：按 DAMAGE/TICK_SEC 结算约 250s，压测窗口内保持交战冻结，不指望 tick 刷血
    local BATTLER_HP = 10000
    local i = 1
    for _ = 1, n_pair do
        local x, y = rand_point(map)
        local a = spawn_march(map, i, { x = x, y = y, hold = true, hp = BATTLER_HP, max_hp = BATTLER_HP })
        local b = spawn_march(map, i + 1, { x = x + 8, y = y, hold = true, hp = BATTLER_HP, max_hp = BATTLER_HP })
        i = i + 2
        if a then
            n_mar = n_mar + 1
        end
        if b then
            n_mar = n_mar + 1
        end
        if a and b then
            local ok, err = march_battle.engage(a, b)
            if ok then
                hs.battlers[a] = true
                hs.battlers[b] = true
                hs.battler_pairs[#hs.battler_pairs + 1] = { a, b }
                n_bat = n_bat + 2
            else
                log.info("[hotspot] engage fail: %s vs %s reason=%s", a, b, tostring(err))
            end
        end
    end
    for j = i, o.marchers do
        if spawn_march(map, j) then
            n_mar = n_mar + 1
        end
    end
    hs.last_stats = view_sync.stats_snapshot()
    hs.last_tick_cost = snapshot_tick_cost()
    skynet.timeout(o.report_interval, function()
        report_tick(map)
    end)
    if n_churn > 0 then
        skynet.timeout(CHURN_TICK, function()
            churn_tick(map)
        end)
    end
    log.info("[hotspot] start: shard=%s center=(%d,%d) r=%d obs=%d churn=%d marchers=%d battlers=%d monsters=%d duration=%ds",
        tostring(map.shard_id), cx, cy, o.radius, n_obs, n_churn, n_mar, n_bat, n_mon, o.duration_sec)
    return true, { observers = n_obs, churners = n_churn, marchers = n_mar, battlers = n_bat, monsters = n_mon, x = cx, y = cy }
end

function M.stop()
    if not hs then
        return false, "hotspot not running"
    end
    local map = ctx.map
    local n_obs, n_mar, n_mon = 0, 0, 0
    if map then
        -- 已迁移到邻片的 churner：本片 leave 不到，远程通知 owner 片清理
        for pid, c in pairs(hs.churn) do
            if c.shard ~= map.shard_id then
                pcall(function()
                    skynet.call(shard.addr(map.map_id, c.shard), "lua", "leave_map", pid)
                end)
            end
        end
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
    local n_churn = 0
    for _ in pairs(hs.churn) do
        n_churn = n_churn + 1
    end
    return true, {
        observers = #hs.observer_list,
        churners = n_churn,
        marchers = march_alive(),
        battlers = n_battles() * 2,
        battles = n_battles(),
        monsters = mon_alive(),
        remain_sec = math.max(0, (hs.deadline - skynet.now()) / 100),
    }
end

return M
