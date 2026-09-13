-- 观察者视野同步：
--   进/离视野 → 观察者差集（enter / leave）
--   属性变化 → 实体侧主动推送 update（不扫周围对象）
local skynet = require "skynet"
local protocol_handler = require "protocol_handler"
local aoi_object = require "map.aoi_object"
local service_ctx = require "runtime.service_ctx"
local helpers = require "map.helpers"
local log = require "log"

local ctx = service_ctx.get("map.map_service", {})
local M = {}

-- 镜头移动差集合并窗口（skynet.timeout 单位 0.01s）
local MOVE_SYNC_COALESCE = 10 -- 100ms

-- P4: 监控统计
local stats = {
    sync_full_count = 0,
    sync_diff_count = 0,
    sync_obj_visible_count = 0,
    sync_obj_attr_count = 0,
    delta_sent_count = 0,
    delta_enter_total = 0,
    delta_leave_total = 0,
    delta_update_total = 0,
    last_reset_time = 0,
}

local function stats_reset()
    stats.sync_full_count = 0
    stats.sync_diff_count = 0
    stats.sync_obj_visible_count = 0
    stats.sync_obj_attr_count = 0
    stats.delta_sent_count = 0
    stats.delta_enter_total = 0
    stats.delta_leave_total = 0
    stats.delta_update_total = 0
    stats.last_reset_time = skynet.now()
end

local function stats_report()
    local now = skynet.now()
    local elapsed = now - stats.last_reset_time
    if elapsed <= 0 then
        return
    end
    local sec = elapsed / 100
    log.info(string.format(
        "[view_sync stats] %.1fs: full=%d diff=%d visible=%d attr=%d delta=%d enter=%d leave=%d update=%d",
        sec,
        stats.sync_full_count,
        stats.sync_diff_count,
        stats.sync_obj_visible_count,
        stats.sync_obj_attr_count,
        stats.delta_sent_count,
        stats.delta_enter_total,
        stats.delta_leave_total,
        stats.delta_update_total
    ))
    stats_reset()
end

-- 每 10 秒输出一次统计
skynet.timeout(1000, function()
    stats_report()
end)

function M.aoi_obj_visible(st, map, obj)
    if not obj then
        return false
    end
    if obj.type == aoi_object.TYPE.MARCH then
        return true
    end
    if aoi_object.is_observer(obj) then
        return false
    end
    local owner_id = obj.owner_player_id or 0
    if owner_id ~= 0 and owner_id ~= st.player_id then
        return false
    end
    return true
end

local function append_to_bucket(monsters, items, marches, buildings, bucket, packed)
    if bucket == "marches" then
        marches[#marches + 1] = packed
    elseif bucket == "monsters" then
        monsters[#monsters + 1] = packed
    elseif bucket == "resources" then
        items[#items + 1] = packed
    elseif bucket == "buildings" then
        buildings[#buildings + 1] = packed
    end
end

local function pack_obj(map, obj, full)
    if not obj then
        return nil, nil
    end
    local bucket = aoi_object.visible_bucket(obj.type)
    if not bucket then
        return nil, nil
    end
    local shard_id = map and map.shard_id or 0
    local packed = aoi_object.pack_visible(obj, {
        shard_id = obj.owner_shard_id or shard_id,
        full = full,
    })
    if not packed then
        return nil, nil
    end
    return bucket, packed
end

-- 当前应可见对象：uid -> obj（不 pack）
function M.collect_visible_objs(map, st)
    local by_uid = {}
    if not st or not st.current_scene_id or st.current_scene_id <= 0 or not map then
        return by_uid
    end
    local seen = {}
    for _, obj in ipairs(map:list_surrounding(st.player_id)) do
        local id = obj.uid
        if not id or seen[id] then
            goto continue
        end
        if obj.alive == false then
            goto continue
        end
        if not M.aoi_obj_visible(st, map, obj) then
            goto continue
        end
        if not aoi_object.visible_bucket(obj.type) then
            goto continue
        end
        seen[id] = true
        by_uid[id] = obj
        ::continue::
    end
    return by_uid
end

function M.collect_visible(map, st)
    local monsters, items, marches, buildings = {}, {}, {}, {}
    for _, obj in pairs(M.collect_visible_objs(map, st)) do
        local bucket, packed = pack_obj(map, obj)
        if bucket and packed then
            append_to_bucket(monsters, items, marches, buildings, bucket, packed)
        end
    end
    return monsters, items, marches, buildings
end

local function commit_visible_uids(st, by_uid)
    local uids = {}
    for uid, _ in pairs(by_uid or {}) do
        uids[uid] = true
    end
    st.visible_uids = uids
end

local function view_grid_of(map, x, y)
    local grid = (map and map.aoi and map.aoi.grid_size) or 50
    local col = math.floor((tonumber(x) or 0) / grid) + 1
    local row = math.floor((tonumber(y) or 0) / grid) + 1
    return row, col
end

local function remember_view_grid(st, map)
    if not st then
        return
    end
    st.view_grid_row, st.view_grid_col = view_grid_of(map, st.x, st.y)
end

function M.clear_view_state(st)
    if not st then
        return
    end
    st.visible_uids = nil
    st.view_grid_row = nil
    st.view_grid_col = nil
    st.pending_view_row = nil
    st.pending_view_col = nil
    st.view_sync_scheduled = nil
end

-- 增量包：enter/leave/update 四桶，空表自动过滤
local function send_delta(player_id, map, delta)
    local enter_m = delta.enter_monsters or {}
    local enter_i = delta.enter_items or {}
    local enter_r = delta.enter_marches or {}
    local enter_b = delta.enter_buildings or {}
    local leave = delta.leave_uids or {}
    local upd_m = delta.update_monsters or {}
    local upd_i = delta.update_items or {}
    local upd_r = delta.update_marches or {}
    local upd_b = delta.update_buildings or {}
    local enter_count = #enter_m + #enter_i + #enter_r + #enter_b
    local leave_count = #leave
    local update_count = #upd_m + #upd_i + #upd_r + #upd_b
    if (enter_count + leave_count + update_count) == 0 then
        return
    end
    stats.delta_sent_count = stats.delta_sent_count + 1
    stats.delta_enter_total = stats.delta_enter_total + enter_count
    stats.delta_leave_total = stats.delta_leave_total + leave_count
    stats.delta_update_total = stats.delta_update_total + update_count
    protocol_handler.send_to_player(player_id, "map_visible_delta_notify", {
        map_id = map and map.map_id or 0,
        enter_monsters = enter_m,
        enter_items = enter_i,
        enter_marches = enter_r,
        enter_buildings = enter_b,
        leave_uids = leave,
        update_monsters = upd_m,
        update_items = upd_i,
        update_marches = upd_r,
        update_buildings = upd_b,
    })
end

function M.sync_full(player_id, map, st)
    stats.sync_full_count = stats.sync_full_count + 1
    local by_uid = M.collect_visible_objs(map, st)
    local monsters, items, marches, buildings = {}, {}, {}, {}
    for _, obj in pairs(by_uid) do
        local bucket, packed = pack_obj(map, obj, true)
        if bucket and packed then
            append_to_bucket(monsters, items, marches, buildings, bucket, packed)
        end
    end
    commit_visible_uids(st, by_uid)
    remember_view_grid(st, map)
    protocol_handler.send_to_player(player_id, "map_visible_sync_notify", {
        map_id = map and map.map_id or 0,
        monsters = monsters,
        items = items,
        marches = marches,
        buildings = buildings,
    })
end

-- 仅进/离视野差集（不做属性 update）
function M.sync_diff(player_id, map, st)
    stats.sync_diff_count = stats.sync_diff_count + 1
    local by_uid = M.collect_visible_objs(map, st)
    local prev = st.visible_uids or {}
    local enter_m, enter_i, enter_r, enter_b = {}, {}, {}, {}
    local leave = {}
    for uid, obj in pairs(by_uid) do
        if not prev[uid] then
            local bucket, packed = pack_obj(map, obj, true)
            if bucket and packed then
                append_to_bucket(enter_m, enter_i, enter_r, enter_b, bucket, packed)
            end
        end
    end
    for uid, _ in pairs(prev) do
        if not by_uid[uid] then
            leave[#leave + 1] = tostring(uid)
        end
    end
    commit_visible_uids(st, by_uid)
    send_delta(player_id, map, {
        enter_monsters = enter_m,
        enter_items = enter_i,
        enter_marches = enter_r,
        enter_buildings = enter_b,
        leave_uids = leave,
    })
end

function M.sync_view(player_id, map, st)
    M.sync_full(player_id, map, st)
end

function M.sync_view_to_players(player_ids, map)
    for _, player_id in ipairs(player_ids or {}) do
        local st = ctx.player_state[player_id]
        if st and map and st.current_map_id == map.map_id then
            M.sync_full(player_id, map, st)
        end
    end
end

-- 镜头移动：AOI 格子未变则跳过；格子变了则 100ms 合并后再推进/离差集
function M.sync_diff_on_move(player_id, map, st)
    if not st or not map then
        return
    end
    local row, col = view_grid_of(map, st.x, st.y)
    if st.view_grid_row == row and st.view_grid_col == col then
        return
    end
    st.pending_view_row = row
    st.pending_view_col = col
    if st.view_sync_scheduled then
        return
    end
    st.view_sync_scheduled = true
    skynet.timeout(MOVE_SYNC_COALESCE, function()
        st.view_sync_scheduled = nil
        if not st.current_scene_id or st.current_scene_id <= 0 then
            return
        end
        local cur_map = helpers.current_map(st)
        if not cur_map then
            return
        end
        local pr, pc = st.pending_view_row, st.pending_view_col
        if pr == nil or pc == nil then
            return
        end
        if st.view_grid_row == pr and st.view_grid_col == pc then
            return
        end
        st.view_grid_row = pr
        st.view_grid_col = pc
        M.sync_diff(player_id, cur_map, st)
    end)
end

-- 判断目标坐标是否在观察者视野格子范围内
local function in_observer_range(map, st, x, y)
    local vr = ctx.MAP_VIEW_RANGE or 0
    local grid_size = (map and map.aoi and map.aoi.grid_size) or 50
    local view_grids = math.ceil(vr / grid_size)
    local center_row, center_col = view_grid_of(map, st.x, st.y)
    local target_row, target_col = view_grid_of(map, x, y)
    return math.abs(target_row - center_row) <= view_grids
        and math.abs(target_col - center_col) <= view_grids
end

local function notify_enter(player_id, map, st, uid, bucket, packed)
    local uids = st.visible_uids
    if not uids then
        uids = {}
        st.visible_uids = uids
    end
    if uids[uid] then
        return
    end
    uids[uid] = true
    local enter_m, enter_i, enter_r, enter_b = {}, {}, {}, {}
    append_to_bucket(enter_m, enter_i, enter_r, enter_b, bucket, packed)
    send_delta(player_id, map, {
        enter_monsters = enter_m,
        enter_items = enter_i,
        enter_marches = enter_r,
        enter_buildings = enter_b,
    })
end

local function notify_leave(player_id, map, st, uid)
    local uids = st.visible_uids
    if not uids or not uids[uid] then
        return
    end
    uids[uid] = nil
    send_delta(player_id, map, { leave_uids = { tostring(uid) } })
end

-- 实体进/离/跨格：按该 uid 对周围观察者补 enter 或 leave（非整表差集）
-- points: 多个位置（如移动的新旧位置），合并去重后一次处理
function M.sync_obj_visible_around(map, points, uid)
    stats.sync_obj_visible_count = stats.sync_obj_visible_count + 1
    if not map or not uid then
        return
    end
    -- 兼容单点 {x, y} 和多点列表
    if points.x ~= nil then
        points = { points }
    end
    if #points == 0 then
        return
    end
    local obj = map:get_obj(uid)
    local bucket, packed
    if obj and obj.alive ~= false and aoi_object.visible_bucket(obj.type) then
        bucket, packed = pack_obj(map, obj, true)
    end
    local seen = {}
    for _, pt in ipairs(points) do
        if pt and pt.x ~= nil then
            for _, o in ipairs(map:observers_around(pt.x, pt.y, ctx.MAP_VIEW_RANGE)) do
                local pid = o.player_id or o.uid
                if pid and not seen[pid] then
                    seen[pid] = true
                    local st = ctx.player_state[pid]
                    if st and st.current_scene_id and st.current_scene_id > 0 and st.current_map_id == map.map_id then
                        local should = false
                        if obj and packed and bucket and M.aoi_obj_visible(st, map, obj) then
                            should = in_observer_range(map, st, obj.x, obj.y)
                        end
                        local has = st.visible_uids and st.visible_uids[uid]
                        if should and not has then
                            notify_enter(pid, map, st, uid, bucket, packed)
                        elseif has and not should then
                            notify_leave(pid, map, st, uid)
                        end
                    end
                end
            end
        end
    end
end

-- 实体属性变化：主动推给「已看见该 uid」的周围观察者
-- 100ms 合并：同一 uid 高频变化只发最后一次
local ATTR_SYNC_COALESCE = 10 -- 100ms
local pending_attr_sync = {} -- uid => { map, obj }

-- 移动同步合并：行军等高频移动 100ms 合并一次推
local MOVE_ATTR_COALESCE = 10 -- 100ms
local pending_move_sync = {} -- uid => { map, obj }

local function flush_attr_sync(uid)
    local pending = pending_attr_sync[uid]
    if not pending then
        return
    end
    pending_attr_sync[uid] = nil
    local map, obj = pending.map, pending.obj
    if not map or not obj then
        return
    end
    -- 合并窗口内对象可能已离开 AOI（死亡/销毁/跨片），不推
    if not map:get_obj(uid) then
        return
    end
    local bucket, packed = pack_obj(map, obj, false)
    if not bucket or not packed then
        return
    end
    -- 推完清脏字段
    aoi_object.clear_dirty(obj)
    local x, y = obj.x or 0, obj.y or 0
    local upd_m, upd_i, upd_r, upd_b = {}, {}, {}, {}
    append_to_bucket(upd_m, upd_i, upd_r, upd_b, bucket, packed)
    local seen = {}
    for _, o in ipairs(map:observers_around(x, y, ctx.MAP_VIEW_RANGE)) do
        local pid = o.player_id or o.uid
        if pid and not seen[pid] then
            seen[pid] = true
            local st = ctx.player_state[pid]
            if st and st.current_scene_id and st.current_scene_id > 0
                and st.current_map_id == map.map_id
                and st.visible_uids and st.visible_uids[uid] then
                send_delta(pid, map, {
                    update_monsters = upd_m,
                    update_items = upd_i,
                    update_marches = upd_r,
                    update_buildings = upd_b,
                })
            end
        end
    end
end

function M.sync_obj_attr_around(map, obj)
    stats.sync_obj_attr_count = stats.sync_obj_attr_count + 1
    if not map or not obj or not obj.uid then
        return
    end
    local uid = obj.uid
    if pending_attr_sync[uid] then
        pending_attr_sync[uid].obj = obj
        return
    end
    pending_attr_sync[uid] = { map = map, obj = obj }
    skynet.timeout(ATTR_SYNC_COALESCE, function()
        flush_attr_sync(uid)
    end)
end

-- 移动同步：高频移动 100ms 合并，只推坐标变化
function M.sync_obj_move_around(map, obj)
    if not map or not obj or not obj.uid then
        return
    end
    local uid = obj.uid
    if pending_move_sync[uid] then
        pending_move_sync[uid].obj = obj
        return
    end
    pending_move_sync[uid] = { map = map, obj = obj }
    skynet.timeout(MOVE_ATTR_COALESCE, function()
        local pending = pending_move_sync[uid]
        if not pending then
            return
        end
        pending_move_sync[uid] = nil
        local m, o = pending.map, pending.obj
        if not m or not o then
            return
        end
        -- 合并窗口内对象可能已离开 AOI（死亡/销毁/跨片），不推
        if not m:get_obj(uid) then
            return
        end
        -- 移动只推坐标，用增量 pack
        local bucket, packed = pack_obj(m, o, false)
        if not bucket or not packed then
            return
        end
        aoi_object.clear_dirty(o)
        local x, y = o.x or 0, o.y or 0
        local upd_m, upd_i, upd_r, upd_b = {}, {}, {}, {}
        append_to_bucket(upd_m, upd_i, upd_r, upd_b, bucket, packed)
        local seen = {}
        for _, obs in ipairs(m:observers_around(x, y, ctx.MAP_VIEW_RANGE)) do
            local pid = obs.player_id or obs.uid
            if pid and not seen[pid] then
                seen[pid] = true
                local st = ctx.player_state[pid]
                if st and st.current_scene_id and st.current_scene_id > 0
                    and st.current_map_id == m.map_id
                    and st.visible_uids and st.visible_uids[uid] then
                    send_delta(pid, m, {
                        update_monsters = upd_m,
                        update_items = upd_i,
                        update_marches = upd_r,
                        update_buildings = upd_b,
                    })
                end
            end
        end
    end)
end

-- P1: 压力测试接口（内部用，不对外）
function M._stress_test(map, observer_count, obj_count)
    local start_time = skynet.now()
    -- 模拟观察者
    local observers = {}
    for i = 1, observer_count do
        local obs = {
            uid = "stress_obs_" .. i,
            player_id = "stress_obs_" .. i,
            x = math.random(0, map.def.width),
            y = math.random(0, map.def.height),
            type = aoi_object.TYPE.OBSERVER,
            view_range = ctx.MAP_VIEW_RANGE,
        }
        map:enter_obj(obs)
        observers[i] = obs
    end
    -- 模拟实体
    local objs = {}
    for i = 1, obj_count do
        local obj = {
            uid = "stress_obj_" .. i,
            x = math.random(0, map.def.width),
            y = math.random(0, map.def.height),
            type = aoi_object.TYPE.MONSTER,
            view_range = 0,
            alive = true,
        }
        map:enter_obj(obj)
        objs[i] = obj
    end
    local enter_time = skynet.now() - start_time
    -- 模拟移动同步
    start_time = skynet.now()
    for _, obj in ipairs(objs) do
        local nx = math.random(0, map.def.width)
        local ny = math.random(0, map.def.height)
        map:move_obj(obj.uid, nx, ny)
    end
    local move_time = skynet.now() - start_time
    -- 清理
    for _, obs in ipairs(observers) do
        map:leave_obj(obs.uid)
    end
    for _, obj in ipairs(objs) do
        map:leave_obj(obj.uid)
    end
    return {
        observer_count = observer_count,
        obj_count = obj_count,
        enter_time_ms = enter_time,
        move_time_ms = move_time,
    }
end

return M
