-- 观察者视野同步：
--   进/离视野 → 观察者差集（enter / leave）
--   属性变化 → 实体侧主动推送 update（不扫周围对象）
--   下发出口 → 按观察者合批：同玩家 100ms 窗口内的 enter/leave/update 合并成一包
local skynet = require "skynet"
local protocol_handler = require "protocol_handler"
local aoi_object = require "map.aoi_object"
local service_ctx = require "runtime.service_ctx"
local helpers = require "map.helpers"
local log = require "log"

local ctx = service_ctx.get("map.shard_service", {})
local M = {}

-- 镜头移动差集合并窗口（skynet.timeout 单位 0.01s）
local MOVE_SYNC_COALESCE = 10 -- 100ms

-- P4: 监控统计
local stats = {
    sync_full_count = 0,
    sync_diff_count = 0,
    sync_obj_visible_count = 0,
    sync_obj_attr_count = 0,
    delta_queued_count = 0,
    delta_sent_count = 0,
    delta_enter_total = 0,
    delta_leave_total = 0,
    delta_update_total = 0,
    delta_bytes_total = 0,    -- 下发字节估算累计（见 est_delta_bytes）
    delta_pkt_bytes_max = 0,  -- 单包估算字节高水位（自上次 reset 起）
    last_reset_time = 0,
}

local function stats_reset()
    stats.sync_full_count = 0
    stats.sync_diff_count = 0
    stats.sync_obj_visible_count = 0
    stats.sync_obj_attr_count = 0
    stats.delta_queued_count = 0
    stats.delta_sent_count = 0
    stats.delta_enter_total = 0
    stats.delta_leave_total = 0
    stats.delta_update_total = 0
    stats.delta_bytes_total = 0
    stats.delta_pkt_bytes_max = 0
    stats.last_reset_time = skynet.now()
end

-- 压测/监控用：计数快照（带时间戳，调用方算增量）与清零
function M.stats_snapshot()
    return {
        sync_full_count = stats.sync_full_count,
        sync_diff_count = stats.sync_diff_count,
        sync_obj_visible_count = stats.sync_obj_visible_count,
        sync_obj_attr_count = stats.sync_obj_attr_count,
        delta_queued_count = stats.delta_queued_count,
        delta_sent_count = stats.delta_sent_count,
        delta_enter_total = stats.delta_enter_total,
        delta_leave_total = stats.delta_leave_total,
        delta_update_total = stats.delta_update_total,
        delta_bytes_total = stats.delta_bytes_total,
        delta_pkt_bytes_max = stats.delta_pkt_bytes_max,
        now = skynet.now(),
    }
end

function M.stats_reset_counters()
    stats_reset()
end

local function stats_report()
    local now = skynet.now()
    local elapsed = now - stats.last_reset_time
    if elapsed <= 0 then
        return
    end
    local sec = elapsed / 100
    log.info(string.format(
        "[view_sync stats] %.1fs: full=%d diff=%d visible=%d attr=%d queued=%d sent=%d enter=%d leave=%d update=%d bytes=%d pktmax=%d",
        sec,
        stats.sync_full_count,
        stats.sync_diff_count,
        stats.sync_obj_visible_count,
        stats.sync_obj_attr_count,
        stats.delta_queued_count,
        stats.delta_sent_count,
        stats.delta_enter_total,
        stats.delta_leave_total,
        stats.delta_update_total,
        stats.delta_bytes_total,
        stats.delta_pkt_bytes_max
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
    -- 建筑（玩家主城）对所有观察者可见
    if obj.type == aoi_object.TYPE.BUILDING then
        return true
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

-- 视野中心 = AOI 观察者实体坐标（镜头位置）；实体缺失时回退原点
local function view_center(map, st)
    local obj = map and st and map:get_obj(st.player_id)
    if obj then
        return obj.x, obj.y
    end
    return 0, 0
end

local function remember_view_grid(st, map)
    if not st then
        return
    end
    st.view_grid_row, st.view_grid_col = view_grid_of(map, view_center(map, st))
end

-- 前向声明：观察者合批冲刷（定义在下方合批区）
local flush_player_batch

function M.clear_view_state(st)
    if not st then
        return
    end
    if st.player_id then
        -- 滞留合批先冲掉：避免旧图 delta 落到新图全量包之后
        flush_player_batch(st.player_id)
    end
    st.visible_uids = nil
    st.view_grid_row = nil
    st.view_grid_col = nil
    st.pending_view_row = nil
    st.pending_view_col = nil
    st.view_sync_scheduled = nil
end

-- 线长估算：真实 sproto 编码在 gate，shard 侧永远看不到字节；此处按 schema 做零成本估算
-- （sproto wire ≈ 每字段 2B tag + 值：int≈4B / double≈8B / string≈4B+len，数组元素另加 4B 头），
-- 误差 ~±20%，只用于压测评估带宽量级，不进任何业务逻辑
local DELTA_PKT_BASE_BYTES = 40 -- 协议头 + map_id + 8 个桶的数组头
local EST_ENTER_BYTES = { monsters = 44, items = 48, marches = 140, buildings = 48 } -- enter = 全量字段（行军含 waypoints 计划）
local EST_UPDATE_BYTES = 30  -- update ≈ uid + x,y 双精度为主的脏字段
local EST_LEAVE_BYTES = 12   -- leave = 纯 uid

local function est_delta_bytes(enter_m, enter_i, enter_r, enter_b, leave, upd_m, upd_i, upd_r, upd_b)
    local function sum(bucket, base)
        local s = 0
        for _, e in pairs(bucket) do
            s = s + base + #(tostring(type(e) == "table" and e.uid or e))
        end
        return s
    end
    return DELTA_PKT_BASE_BYTES
        + sum(enter_m, EST_ENTER_BYTES.monsters) + sum(enter_i, EST_ENTER_BYTES.items)
        + sum(enter_r, EST_ENTER_BYTES.marches) + sum(enter_b, EST_ENTER_BYTES.buildings)
        + sum(upd_m, EST_UPDATE_BYTES) + sum(upd_i, EST_UPDATE_BYTES)
        + sum(upd_r, EST_UPDATE_BYTES) + sum(upd_b, EST_UPDATE_BYTES)
        + sum(leave, EST_LEAVE_BYTES)
end

-- 增量包：enter/leave/update 四桶，空表自动过滤（真正发包点，全文件唯一出口）
local function do_send_delta(player_id, map, delta)
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
    local pkt_bytes = est_delta_bytes(enter_m, enter_i, enter_r, enter_b,
        leave, upd_m, upd_i, upd_r, upd_b)
    stats.delta_bytes_total = stats.delta_bytes_total + pkt_bytes
    if pkt_bytes > stats.delta_pkt_bytes_max then
        stats.delta_pkt_bytes_max = pkt_bytes
    end
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

---------------------------------------------------------------------------
-- 观察者合批：同一玩家的 enter/leave/update 在 BATCH_COALESCE 窗口内合并成一包。
-- 不变式：flush 出的包里，一个 uid 只会出现在 enter / update / leave 其中一类。
-- 合并规则：
--   enter + leave → 对消（enter 尚未发出，客户端从未见过，无需任何包）
--   leave + enter → 净 enter（全量包刷新；要求客户端 enter 为 upsert 语义）
--   leave        → 优先于 update（客户端即将删除，无需再更新）
--   enter + update → update 字段合并进 enter 全量包
---------------------------------------------------------------------------
local BATCH_COALESCE = 10 -- 100ms（skynet.timeout 单位 0.01s）

local DELTA_SUFFIX = { "monsters", "items", "marches", "buildings" }

-- player_id => {
--   map = map, scheduled = bool,
--   enter_monsters/items/marches/buildings = { uid -> packed },
--   update_* 同上,
--   leave_uids = { uid -> true },
-- }
local pending_batches = {}

local function queue_enter(pend, suffix, uid, packed)
    -- leave + enter → 净 enter（移除滞留 leave）
    pend.leave_uids[uid] = nil
    for _, s in ipairs(DELTA_SUFFIX) do
        -- enter 是全量包且更新鲜：滞留 update 被其覆盖，丢弃（正常时序不应存在，防御性）
        pend["update_" .. s][uid] = nil
        -- 重复 enter 以最新全量包为准
        pend["enter_" .. s][uid] = nil
    end
    pend["enter_" .. suffix][uid] = packed
end

local function queue_leave(pend, uid)
    local had_enter = false
    for _, s in ipairs(DELTA_SUFFIX) do
        if pend["enter_" .. s][uid] then
            pend["enter_" .. s][uid] = nil
            had_enter = true
        end
        pend["update_" .. s][uid] = nil
    end
    -- enter + leave 窗口内对消：enter 未发出过，客户端从未见过该 uid
    if not had_enter then
        pend.leave_uids[uid] = true
    end
end

local function queue_update(pend, suffix, uid, packed)
    if pend.leave_uids[uid] then
        return -- leave 优先
    end
    -- 已有 enter：合并进全量包（字段覆盖即最新值）
    for _, s in ipairs(DELTA_SUFFIX) do
        local e = pend["enter_" .. s][uid]
        if e then
            for k, v in pairs(packed) do
                e[k] = v
            end
            return
        end
    end
    -- 合并到 update：同 uid 字段覆盖，只留最终态
    local bucket = pend["update_" .. suffix]
    local old = bucket[uid]
    if old then
        for k, v in pairs(packed) do
            old[k] = v
        end
    else
        bucket[uid] = packed
    end
end

flush_player_batch = function(player_id)
    local pend = pending_batches[player_id]
    if not pend then
        return
    end
    pending_batches[player_id] = nil
    local delta = { leave_uids = {} }
    for uid in pairs(pend.leave_uids) do
        delta.leave_uids[#delta.leave_uids + 1] = uid
    end
    for _, s in ipairs(DELTA_SUFFIX) do
        local ek, uk = "enter_" .. s, "update_" .. s
        local ea, ua = {}, {}
        for _, packed in pairs(pend[ek]) do
            ea[#ea + 1] = packed
        end
        for _, packed in pairs(pend[uk]) do
            ua[#ua + 1] = packed
        end
        delta[ek] = ea
        delta[uk] = ua
    end
    do_send_delta(player_id, pend.map, delta)
end

-- 下发入口（替代原 send_delta）：合入该玩家的批次，窗口到点统一发
local function queue_delta(player_id, map, delta)
    stats.delta_queued_count = stats.delta_queued_count + 1
    local pend = pending_batches[player_id]
    if pend and pend.map ~= map then
        -- 换图/跨片：旧批次先冲，避免旧图 delta 落到新图全量包之后
        flush_player_batch(player_id)
        pend = nil
    end
    if not pend then
        pend = { map = map, leave_uids = {} }
        for _, s in ipairs(DELTA_SUFFIX) do
            pend["enter_" .. s] = {}
            pend["update_" .. s] = {}
        end
        pending_batches[player_id] = pend
    end
    for _, s in ipairs(DELTA_SUFFIX) do
        for _, packed in ipairs(delta["enter_" .. s] or {}) do
            queue_enter(pend, s, tostring(packed.uid), packed)
        end
        for _, packed in ipairs(delta["update_" .. s] or {}) do
            queue_update(pend, s, tostring(packed.uid), packed)
        end
    end
    for _, uid in ipairs(delta.leave_uids or {}) do
        queue_leave(pend, tostring(uid))
    end
    if not pend.scheduled then
        pend.scheduled = true
        skynet.timeout(BATCH_COALESCE, function()
            flush_player_batch(player_id)
        end)
    end
end

function M.sync_full(player_id, map, st)
    stats.sync_full_count = stats.sync_full_count + 1
    -- 全量前先冲掉滞留合批，保证线上顺序：delta 在前、full 在后
    flush_player_batch(player_id)
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
    queue_delta(player_id, map, {
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
    local row, col = view_grid_of(map, view_center(map, st))
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

-- 判断目标坐标是否在观察者视野格子范围内（视野中心 = 镜头位置）
local function in_observer_range(map, st, x, y)
    local vr = ctx.MAP_VIEW_RANGE or 0
    local grid_size = (map and map.aoi and map.aoi.grid_size) or 50
    local view_grids = math.ceil(vr / grid_size)
    local center_row, center_col = view_grid_of(map, view_center(map, st))
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
    queue_delta(player_id, map, {
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
    queue_delta(player_id, map, { leave_uids = { tostring(uid) } })
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
                queue_delta(pid, map, {
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
                    queue_delta(pid, m, {
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
