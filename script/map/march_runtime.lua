local skynet = require "skynet"
local log = require "log"
local protocol_handler = require "protocol_handler"
local shard = require "map.shard"
local march = require "map.march"
local aoi_object = require "map.aoi_object"
local map_store = require "map.map_store"
local service_ctx = require "runtime.service_ctx"
local view = require "map.view_sync"
local helpers = require "map.helpers"

local ctx = service_ctx.get("map.shard_service", {})
local M = {}

ctx.marches = ctx.marches or {}
ctx.player_marches = ctx.player_marches or {}
ctx.field_battles = ctx.field_battles or {}
ctx.march_seq = ctx.march_seq or {}
ctx.CHASE_REPATH_DIST = 32
ctx.PATHFINDING_NAME = ".pathfinding"

local function index_player_march(player_id, uid)
    if not player_id or not uid then
        return
    end
    local t = ctx.player_marches[player_id]
    if not t then
        t = {}
        ctx.player_marches[player_id] = t
    end
    t[uid] = true
end

local function unindex_player_march(player_id, uid)
    local t = ctx.player_marches[player_id]
    if t then
        t[uid] = nil
    end
end

local function count_player_marches(player_id)
    local n = 0
    local t = ctx.player_marches[player_id]
    if not t then
        return 0
    end
    for uid, _ in pairs(t) do
        if ctx.marches[uid] then
            n = n + 1
        end
    end
    return n
end

function M.query_march_count(player_id)
    return count_player_marches(player_id)
end

local function count_all_player_marches(player_id)
    local n = count_player_marches(player_id)
    local map = ctx.map
    if not map then
        return n
    end
    for _, sid in ipairs(shard.all_ids()) do
        if sid ~= map.shard_id then
            local addr = shard.addr(map.map_id, sid)
            if addr then
                n = n + (skynet.call(addr, "lua", "query_march_count", player_id) or 0)
            end
        end
    end
    return n
end

local function pick_player_march(player_id, march_uid)
    march_uid = tostring(march_uid or "")
    if march_uid ~= "" then
        local m = ctx.marches[march_uid]
        if m and m.owner_player_id == player_id then
            return m
        end
        return nil
    end
    local t = ctx.player_marches[player_id]
    if not t then
        return nil
    end
    for uid, _ in pairs(t) do
        local m = ctx.marches[uid]
        if m and m.owner_player_id == player_id then
            return m
        end
    end
    return nil
end

local function remember_owner_march(player_id, uid, shard_id, removed)
    if not player_id or not uid then
        return
    end
    protocol_handler.send_to_agent(player_id, "remember_march", {
        player_id = player_id,
        march_uid = uid,
        shard_id = shard_id or 0,
        removed = removed and true or false,
    })
end

local function notify_march_sync(map, m, removed)
    if not m then
        return
    end
    local payload = {
        map_id = map and map.map_id or 0,
        marches = (not removed) and { march.pack_visible(m, map and map.shard_id) } or {},
        removed_uid = removed and (m.uid or "") or "",
        shard_id = map and map.shard_id or 0,
    }
    if m.owner_player_id then
        protocol_handler.send_to_player(m.owner_player_id, "map_march_sync_notify", payload)
    end
end

local function notify_field_battle(map, battle, phase, extra)
    if not battle then
        return
    end
    extra = extra or {}
    local msg = {
        map_id = map and map.map_id or 0,
        battle_id = battle.id or "",
        phase = phase or "",
        attacker_uid = battle.attacker_uid or "",
        defender_uid = battle.defender_uid or "",
        attacker_hp = extra.attacker_hp or 0,
        defender_hp = extra.defender_hp or 0,
        reason = extra.reason or "",
        shard_id = map and map.shard_id or 0,
    }
    if battle.attacker_player_id then
        protocol_handler.send_to_player(battle.attacker_player_id, "map_march_battle_notify", msg)
    end
    if battle.defender_player_id and battle.defender_player_id ~= battle.attacker_player_id then
        protocol_handler.send_to_player(battle.defender_player_id, "map_march_battle_notify", msg)
    end
end

local function clear_march_battle_fields(m, keep_chase)
    if not m then
        return
    end
    m.battle_id = nil
    m.host_shard_id = nil
    m.role = nil
    aoi_object.mark_dirty(m, "battle_id")
    if keep_chase and m.target_uid and m.alive then
        m.state = march.STATE_CHASE
    else
        m.state = march.STATE_MARCHING
        if not keep_chase then
            m.target_uid = nil
            aoi_object.mark_dirty(m, "target_uid")
        end
    end
    aoi_object.mark_dirty(m, "state")
end

local end_field_battle
local despawn_march

local function query_sid_march(map, sid, uid)
    if not map or sid == nil or sid == map.shard_id then
        return nil
    end
    local addr = shard.addr(map.map_id, sid)
    if not addr then
        return nil
    end
    local ok, snap = skynet.call(addr, "lua", "query_march", uid)
    if ok and type(snap) == "table" then
        return snap
    end
    return nil
end

local function resolve_target(map, uid, hint_shard)
    uid = tostring(uid or "")
    if uid == "" or not map then
        return nil
    end
    local local_m = ctx.marches[uid]
    if local_m and local_m.alive then
        return {
            uid = uid,
            x = local_m.x,
            y = local_m.y,
            hp = local_m.hp,
            max_hp = local_m.max_hp,
            owner_player_id = local_m.owner_player_id,
            shard_id = map.shard_id,
            battle_id = local_m.battle_id or "",
            local_march = local_m,
        }
    end
    local ghost = march.from_ghost(map:get_obj(uid))
    local snap = query_sid_march(map, hint_shard, uid)
    if not snap and ghost then
        snap = query_sid_march(map, ghost.shard_id, uid)
    end
    if not snap then
        for _, nid in ipairs(map:neighbor_ids()) do
            snap = query_sid_march(map, nid, uid)
            if snap then
                break
            end
        end
    end
    if snap then
        return snap
    end
    return ghost
end

-- 野战开始：attacker 本片发起，defender 可能跨片（march_set_defender 通知）
local function start_field_battle(map, atk, target)
    if not atk or not target then
        return false, "invalid target"
    end
    if atk.battle_id then
        return false, "already in battle"
    end
    if target.battle_id and target.battle_id ~= "" then
        return false, "目标交战中"
    end
    if target.owner_player_id == atk.owner_player_id then
        return false, "不能攻击自己的行军"
    end
    local battle = {
        id = string.format("fb_%s_%d", atk.uid, skynet.now()),
        attacker_uid = atk.uid,
        attacker_player_id = atk.owner_player_id,
        defender_uid = target.uid,
        defender_player_id = target.owner_player_id,
        defender_shard = target.shard_id or map.shard_id,
        host_shard = map.shard_id,
    }
    local def_local = target.local_march or ctx.marches[target.uid]
    if def_local then
        if def_local.battle_id then
            return false, "目标交战中"
        end
        def_local.battle_id = battle.id
        def_local.host_shard_id = map.shard_id
        def_local.role = "defender"
        def_local.state = march.STATE_BATTLE
    else
        local addr = shard.addr(map.map_id, battle.defender_shard)
        if not addr then
            return false, "目标战区不可用"
        end
        local ok, err = skynet.call(addr, "lua", "march_set_defender", target.uid, {
            battle_id = battle.id,
            host_shard = map.shard_id,
            attacker_uid = atk.uid,
            attacker_player_id = atk.owner_player_id,
        })
        if not ok then
            return false, err or "目标交战中"
        end
    end
    atk.battle_id = battle.id
    atk.host_shard_id = map.shard_id
    atk.role = "attacker"
    atk.state = march.STATE_BATTLE
    atk.target_uid = target.uid
    atk.target_shard_id = battle.defender_shard
    aoi_object.mark_dirty(atk, "state")
    aoi_object.mark_dirty(atk, "battle_id")
    aoi_object.mark_dirty(atk, "target_uid")
    ctx.field_battles[battle.id] = battle
    if atk.in_aoi then
        map:sync_ghosts(atk)
        view.sync_obj_attr_around(map, atk)
    end
    if def_local and def_local.in_aoi then
        map:sync_ghosts(def_local)
        view.sync_obj_attr_around(map, def_local)
    end
    notify_field_battle(map, battle, "engage", {
        attacker_hp = atk.hp or 0,
        defender_hp = target.hp or 0,
    })
    return true
end

-- 野战结束：清双方战斗状态，defender 跨片则通知其 owner shard
end_field_battle = function(battle, reason)
    if not battle then
        return
    end
    local map = ctx.map
    if ctx.field_battles[battle.id] then
        ctx.field_battles[battle.id] = nil
    end
    local atk = ctx.marches[battle.attacker_uid]
    if atk then
        clear_march_battle_fields(atk, atk.target_uid and true or false)
        if map and atk.in_aoi then
            map:sync_ghosts(atk)
            view.sync_obj_attr_around(map, atk)
        end
    end
    local def = ctx.marches[battle.defender_uid]
    if def then
        clear_march_battle_fields(def, false)
        if map and def.in_aoi then
            map:sync_ghosts(def)
            view.sync_obj_attr_around(map, def)
        end
    elseif map and battle.defender_shard ~= nil and battle.defender_shard ~= (map.shard_id) then
        local addr = shard.addr(map.map_id, battle.defender_shard)
        if addr then
            skynet.send(addr, "lua", "march_clear_battle", battle.defender_uid, battle.id, reason)
        end
    end
    notify_field_battle(map, battle, "end", { reason = reason or "" })
end

-- 行军销毁：结束战斗、离 AOI、清索引、通知 owner
despawn_march = function(map, m, reason, skip_end_battle)
    if not m then
        return
    end
    if not skip_end_battle and m.battle_id then
        local battle = ctx.field_battles[m.battle_id]
        if battle then
            end_field_battle(battle, reason or "despawn")
        elseif map and m.host_shard_id and m.host_shard_id ~= map.shard_id then
            local addr = shard.addr(map.map_id, m.host_shard_id)
            if addr then
                skynet.send(addr, "lua", "end_hosted_battle", m.battle_id, reason or "despawn")
            end
        end
    end
    if map and m.in_aoi then
        pcall(function()
            map:leave_obj(m.uid)
        end)
        m.in_aoi = false
    end
    ctx.marches[m.uid] = nil
    unindex_player_march(m.owner_player_id, m.uid)
    remember_owner_march(m.owner_player_id, m.uid, map and map.shard_id, true)
    notify_march_sync(map, m, true)
end

-- 行军进 AOI：坐标取整（AOI 格子索引用整数）
local function attach_march_aoi(map, m)
    march.bind_map(m, map.map_id, map.shard_id)
    local ix = math.floor((m.x or 0) + 0.5)
    local iy = math.floor((m.y or 0) + 0.5)
    m.x, m.y = ix, iy
    local ok, err = map:enter_obj(m)
    if ok then
        m.in_aoi = true
        m.shard_id = map.shard_id
    end
    return ok, err
end

-- 行军 AOI 同步：坐标变了 move_obj，没变但属性变了也要推 ghost/attr
-- is_new_action: 新行为（march_start/march_attack）立即推，持续移动（tick）合并推
local function sync_march_aoi(map, m, force_notify, is_new_action)
    local ix = math.floor((m.x or 0) + 0.5)
    local iy = math.floor((m.y or 0) + 0.5)
    -- 用 AOI 里的 _aoi_x/_aoi_y 判断是否真的变了（避免浮点抖动）
    local obj = map:get_obj(m.uid)
    local old_x = obj and obj._aoi_x or m.x
    local old_y = obj and obj._aoi_y or m.y
    if m.in_aoi and (ix ~= old_x or iy ~= old_y) then
        map:move_obj(m.uid, ix, iy)
        aoi_object.mark_dirty(m, "x")
        aoi_object.mark_dirty(m, "y")
        if is_new_action then
            -- 新行为：立即推，不合并
            view.sync_obj_attr_around(map, m)
        else
            -- 持续移动：合并推
            view.sync_obj_move_around(map, m)
        end
    elseif m.in_aoi then
        -- hp/state 等非坐标变化仍要推 ghost
        map:sync_ghosts(m)
    end
    if force_notify or march.dist2(m.x, m.y, m.last_notify_x, m.last_notify_y) >= (march.NOTIFY_MOVE * march.NOTIFY_MOVE) then
        m.last_notify_x, m.last_notify_y = m.x, m.y
        notify_march_sync(map, m)
        if m.in_aoi then
            view.sync_obj_attr_around(map, m)
        end
    end
end

-- 跨片 handoff：行军位置超出本片则迁移到目标片，失败则回滚
-- P3: 迁移锁：handoff 期间锁定 battle，防双方同时迁移导致状态分裂
local function try_handoff_march(map, m)
    local dest = shard.shard_id_of_pos(m.x, m.y, map.def)
    if dest == map.shard_id then
        return false
    end
    local addr = shard.addr(map.map_id, dest)
    if not addr then
        local x0, y0, x1, y1 = shard.pixel_rect(map.shard_id, map.def)
        m.x = math.max(x0, math.min(x1, m.x))
        m.y = math.max(y0, math.min(y1, m.y))
        return false
    end
    -- P3: 如果行军是 attacker 且在战斗中，先锁定 battle 防 defender 同时 handoff
    local battle_lock_key = nil
    if m.role == "attacker" and m.battle_id then
        battle_lock_key = "handoff_lock:" .. m.battle_id
        if not M.acquire_lock(battle_lock_key) then
            -- 对方也在 handoff，等待下 tick
            return false
        end
    end
    local snap = { march = march.export(m) }
    if m.role == "attacker" and m.battle_id then
        snap.battle = ctx.field_battles[m.battle_id]
    end
    if m.in_aoi then
        pcall(function()
            map:leave_obj(m.uid)
        end)
        m.in_aoi = false
    end
    ctx.marches[m.uid] = nil
    unindex_player_march(m.owner_player_id, m.uid)
    if snap.battle then
        ctx.field_battles[snap.battle.id] = nil
    end
    local ok, result = skynet.call(addr, "lua", "accept_march_handoff", snap)
    if not ok then
        m.x, m.y = march.clamp(map.def, m.x, m.y)
        if not map:owns_pos(m.x, m.y) then
            local x0, y0, x1, y1 = shard.pixel_rect(map.shard_id, map.def)
            m.x = math.max(x0, math.min(x1, m.x))
            m.y = math.max(y0, math.min(y1, m.y))
        end
        ctx.marches[m.uid] = m
        index_player_march(m.owner_player_id, m.uid)
        if snap.battle then
            ctx.field_battles[snap.battle.id] = snap.battle
        end
        attach_march_aoi(map, m)
        log.error("march handoff failed, uid=%s dest=%s err=%s", tostring(m.uid), tostring(dest), tostring(result))
        if battle_lock_key then
            M.release_lock(battle_lock_key)
        end
        return false
    end
    if battle_lock_key then
        M.release_lock(battle_lock_key)
    end
    remember_owner_march(m.owner_player_id, m.uid, dest, false)
    return true
end

local function find_map_path(map, x1, y1, x2, y2, keep_end)
    local addr = skynet.localname(ctx.PATHFINDING_NAME)
    if not addr then
        log.warning("pathfinding unavailable, fallback straight line")
        return { { x = x1, y = y1 }, { x = x2, y = y2 } }
    end
    local ok, result = skynet.call(addr, "lua", "find_path", map.map_id, x1, y1, x2, y2, keep_end and true or false)
    if not ok then
        return nil, result or "找不到路径"
    end
    if type(result) ~= "table" or #result == 0 then
        return nil, "找不到路径"
    end
    return result
end

local function apply_march_path(m, path, tx, ty)
    march.set_path(m, path)
    m.last_path_tx = tx
    m.last_path_ty = ty
end

-- 追击重寻路：目标移动超过 CHASE_REPATH_DIST 或无路径时重新找路
local function maybe_repath_chase(map, m, tgt)
    local arrived = not (m.waypoints and m.waypoints[m.wp_index or 1])
    local need = arrived
    if m.last_path_tx and m.last_path_ty then
        if march.dist2(m.last_path_tx, m.last_path_ty, tgt.x, tgt.y) >= (ctx.CHASE_REPATH_DIST * ctx.CHASE_REPATH_DIST) then
            need = true
        end
    else
        need = true
    end
    if not need then
        return
    end
    local path = find_map_path(map, m.x, m.y, tgt.x, tgt.y, true)
    if not path then
        path = { { x = m.x, y = m.y }, { x = tgt.x, y = tgt.y } }
    end
    apply_march_path(m, path, tgt.x, tgt.y)
end

-- 单个行军 tick：追击/战斗/移动/跨片/同步
local function tick_one_march(map, m)
    local hold = (m.state == march.STATE_BATTLE and m.role == "defender")
    if m.state == march.STATE_CHASE or (m.state == march.STATE_BATTLE and m.role == "attacker") then
        local tgt = resolve_target(map, m.target_uid, m.target_shard_id)
        if tgt then
            m.target_shard_id = tgt.shard_id
            if not m.battle_id and march.in_range(m.x, m.y, tgt.x, tgt.y, march.ENGAGE_RANGE) then
                start_field_battle(map, m, tgt)
                hold = true
            elseif march.in_range(m.x, m.y, tgt.x, tgt.y, march.ENGAGE_RANGE) then
                hold = true
            else
                maybe_repath_chase(map, m, tgt)
            end
        end
    end
    if not hold then
        local tx, ty = march.current_dest(m)
        local nx, ny = march.step(m.x, m.y, tx, ty, m.speed, march.TICK_SEC)
        m.x, m.y = march.clamp(map.def, nx, ny)
        local wp = m.waypoints and m.waypoints[m.wp_index or 1]
        if wp and march.in_range(m.x, m.y, wp.x, wp.y, 1.5) then
            m.wp_index = (m.wp_index or 1) + 1
        end
    end
    if try_handoff_march(map, m) then
        return
    end
    sync_march_aoi(map, m, false, false)  -- tick 持续移动，合并推
end

-- 单个野战 tick：扣血、推属性、判死亡结束
local function tick_one_battle(map, battle)
    local atk = ctx.marches[battle.attacker_uid]
    if not atk or not atk.alive then
        end_field_battle(battle, "attacker_gone")
        return
    end
    local tgt = resolve_target(map, battle.defender_uid, battle.defender_shard)
    if not tgt then
        end_field_battle(battle, "defender_gone")
        return
    end
    battle.defender_shard = tgt.shard_id or battle.defender_shard
    if not march.in_range(atk.x, atk.y, tgt.x, tgt.y, march.DISENGAGE_RANGE) then
        end_field_battle(battle, "disengage")
        return
    end
    if not march.in_range(atk.x, atk.y, tgt.x, tgt.y, march.ENGAGE_RANGE) then
        return
    end
    atk.hp = math.max(0, (atk.hp or 0) - march.DAMAGE)
    aoi_object.mark_dirty(atk, "hp")
    local def_hp = tgt.hp or 0
    local def_dead = false
    if tgt.local_march then
        tgt.local_march.hp = math.max(0, (tgt.local_march.hp or 0) - march.DAMAGE)
        aoi_object.mark_dirty(tgt.local_march, "hp")
        def_hp = tgt.local_march.hp
        def_dead = def_hp <= 0
    else
        local addr = shard.addr(map.map_id, tgt.shard_id)
        if addr then
            local ok, result = skynet.call(addr, "lua", "apply_march_damage", tgt.uid, march.DAMAGE, battle.id)
            if ok and type(result) == "table" then
                def_hp = result.hp or 0
                def_dead = result.dead and true or false
            end
        end
    end
    notify_field_battle(map, battle, "tick", {
        attacker_hp = atk.hp or 0,
        defender_hp = def_hp,
    })
    if atk.in_aoi then
        map:sync_ghosts(atk)
        view.sync_obj_attr_around(map, atk)
    end
    if tgt.local_march and tgt.local_march.in_aoi then
        map:sync_ghosts(tgt.local_march)
        view.sync_obj_attr_around(map, tgt.local_march)
    end
    if atk.hp <= 0 then
        end_field_battle(battle, "attacker_dead")
        despawn_march(map, atk, "dead", true)
    elseif def_dead then
        end_field_battle(battle, "defender_dead")
        if tgt.local_march then
            despawn_march(map, tgt.local_march, "dead", true)
        end
    end
end

function M.tick_marches()
    local map = ctx.map
    if not map then
        return
    end
    local uids = {}
    for uid, _ in pairs(ctx.marches) do
        uids[#uids + 1] = uid
    end
    for _, uid in ipairs(uids) do
        local m = ctx.marches[uid]
        if m and m.alive then
            tick_one_march(map, m)
        end
    end
    local bids = {}
    for id, _ in pairs(ctx.field_battles) do
        bids[#bids + 1] = id
    end
    for _, id in ipairs(bids) do
        local battle = ctx.field_battles[id]
        if battle then
            tick_one_battle(map, battle)
        end
    end
end

function M.despawn_player_marches(player_id)
    local map = ctx.map
    local t = ctx.player_marches[player_id]
    if not t then
        return
    end
    local uids = {}
    for uid, _ in pairs(t) do
        uids[#uids + 1] = uid
    end
    for _, uid in ipairs(uids) do
        local m = ctx.marches[uid]
        if m then
            despawn_march(map, m, "leave")
        end
    end
    ctx.player_marches[player_id] = nil
end

-- 行军从主城出发：本 CMD 应落在主城所在片（net 层按 city_shard_id_ 路由），
-- 起点读主城实体（本片权威），不依赖 player_state
function M.march_start(player_id, x, y)
    local map = ctx.map
    if not map then
        return false, "map not found"
    end
    local city = map:get_city(player_id)
    if not city then
        return false, "主城不在本战区"
    end
    if count_all_player_marches(player_id) >= march.MAX_PER_PLAYER then
        return false, "行军数量已满"
    end
    x, y = march.clamp(map.def, x, y)
    local path, path_err = find_map_path(map, city.x, city.y, x, y)
    if not path then
        return false, path_err or "无法到达目标"
    end
    local dest = path[#path]
    ctx.march_seq[player_id] = (ctx.march_seq[player_id] or 0) + 1
    local uid = string.format("m_%d_%d_%d", player_id, map.shard_id, ctx.march_seq[player_id])
    local m = march.new({
        uid = uid,
        owner_player_id = player_id,
        x = city.x,
        y = city.y,
        waypoints = path,
        shard_id = map.shard_id,
        state = march.STATE_MARCHING,
        last_path_tx = dest.x,
        last_path_ty = dest.y,
    })
    ctx.marches[uid] = m
    index_player_march(player_id, uid)
    local ok, err = attach_march_aoi(map, m)
    if not ok then
        ctx.marches[uid] = nil
        unindex_player_march(player_id, uid)
        return false, err or "行军进入场景失败"
    end
    remember_owner_march(player_id, uid, map.shard_id, false)
    notify_march_sync(map, m)
    -- 新行为：立即推，不合并
    sync_march_aoi(map, m, true, true)
    return true, helpers.with_shard(map, {
        march_uid = uid,
        x = math.floor(m.x + 0.5),
        y = math.floor(m.y + 0.5),
        dest_x = math.floor(dest.x + 0.5),
        dest_y = math.floor(dest.y + 0.5),
        hp = m.hp,
        max_hp = m.max_hp,
        state = m.state,
    })
end

function M.march_attack(player_id, march_uid, target_uid)
    local map = ctx.map
    if not map then
        return false, "map not found"
    end
    target_uid = tostring(target_uid or "")
    if target_uid == "" then
        return false, "target_uid is required"
    end
    local m = pick_player_march(player_id, march_uid)
    if not m then
        return false, "march not found"
    end
    if m.uid == target_uid then
        return false, "不能攻击自己的行军"
    end
    local tgt = resolve_target(map, target_uid, m.target_shard_id)
    if not tgt then
        return false, "目标不在范围内"
    end
    if tgt.owner_player_id == player_id then
        return false, "不能攻击自己的行军"
    end
    m.target_uid = target_uid
    m.target_shard_id = tgt.shard_id
    aoi_object.mark_dirty(m, "target_uid")
    if not m.battle_id then
        m.state = march.STATE_CHASE
        aoi_object.mark_dirty(m, "state")
        if march.in_range(m.x, m.y, tgt.x, tgt.y, march.ENGAGE_RANGE) then
            local ok, err = start_field_battle(map, m, tgt)
            if not ok then
                return false, err
            end
        else
            local path = find_map_path(map, m.x, m.y, tgt.x, tgt.y, true)
            if not path then
                path = { { x = m.x, y = m.y }, { x = tgt.x, y = tgt.y } }
            end
            apply_march_path(m, path, tgt.x, tgt.y)
        end
    end
    notify_march_sync(map, m)
    -- 新行为：立即推，不合并
    sync_march_aoi(map, m, true, true)
    return true, helpers.with_shard(map, {
        march_uid = m.uid,
        target_uid = target_uid,
        state = m.state,
        battle_id = m.battle_id or "",
    })
end

function M.march_cancel(player_id, march_uid)
    local map = ctx.map
    local m = pick_player_march(player_id, march_uid)
    if not m then
        return false, "march not found"
    end
    local uid = m.uid
    despawn_march(map, m, "cancel")
    return true, helpers.with_shard(map, {
        march_uid = uid,
        removed = true,
    })
end

function M.query_march(uid)
    local map = ctx.map
    local m = ctx.marches[tostring(uid or "")]
    if not m or not m.alive then
        return false, "march not found"
    end
    return true, {
        uid = m.uid,
        x = m.x,
        y = m.y,
        hp = m.hp,
        max_hp = m.max_hp,
        owner_player_id = m.owner_player_id,
        shard_id = map and map.shard_id,
        battle_id = m.battle_id or "",
        state = m.state,
    }
end

function M.apply_march_damage(uid, dmg, battle_id)
    local map = ctx.map
    local m = ctx.marches[tostring(uid or "")]
    if not m then
        return false, "march not found"
    end
    if battle_id and m.battle_id and tostring(battle_id) ~= tostring(m.battle_id) then
        return false, "battle mismatch"
    end
    m.hp = math.max(0, (m.hp or 0) - (tonumber(dmg) or 0))
    aoi_object.mark_dirty(m, "hp")
    if m.hp <= 0 then
        m.alive = false
        despawn_march(map, m, "dead", true)
        return true, { hp = 0, dead = true }
    end
    notify_march_sync(map, m)
    if map and m.in_aoi then
        map:sync_ghosts(m)
        view.sync_obj_attr_around(map, m)
    end
    return true, { hp = m.hp, dead = false }
end

function M.march_set_defender(uid, info)
    local map = ctx.map
    local m = ctx.marches[tostring(uid or "")]
    if not m or not m.alive then
        return false, "march not found"
    end
    if m.battle_id then
        return false, "目标交战中"
    end
    info = info or {}
    m.battle_id = info.battle_id
    m.host_shard_id = info.host_shard
    m.role = "defender"
    m.state = march.STATE_BATTLE
    aoi_object.mark_dirty(m, "state")
    aoi_object.mark_dirty(m, "battle_id")
    if map and m.in_aoi then
        map:sync_ghosts(m)
        view.sync_obj_attr_around(map, m)
    end
    return true
end

function M.march_clear_battle(uid, battle_id, _reason)
    local map = ctx.map
    local m = ctx.marches[tostring(uid or "")]
    if not m then
        return true
    end
    if battle_id and m.battle_id and tostring(m.battle_id) ~= tostring(battle_id) then
        return true
    end
    clear_march_battle_fields(m, false)
    if map and m.in_aoi then
        map:sync_ghosts(m)
        view.sync_obj_attr_around(map, m)
    end
    return true
end

function M.march_update_host(uid, battle_id, host_shard)
    local m = ctx.marches[tostring(uid or "")]
    if m and (not battle_id or tostring(m.battle_id) == tostring(battle_id)) then
        m.host_shard_id = host_shard
    end
    return true
end

function M.battle_defender_moved(battle_id, dest_shard, _uid)
    local battle = ctx.field_battles[tostring(battle_id or "")]
    if battle then
        battle.defender_shard = dest_shard
    end
    return true
end

function M.end_hosted_battle(battle_id, reason)
    local battle = ctx.field_battles[tostring(battle_id or "")]
    if battle then
        end_field_battle(battle, reason or "remote_end")
    end
    return true
end

-- 跨片行军接收：重建行军、恢复战斗状态、通知相关方
-- P3: defender handoff 时检查 battle 锁，若 attacker 也在 handoff 则等待
function M.accept_march_handoff(snap)
    local map = ctx.map
    if not map or type(snap) ~= "table" or type(snap.march) ~= "table" then
        return false, "invalid handoff"
    end
    local m = march.from_export(snap.march)
    m.x, m.y = march.clamp(map.def, m.x, m.y)
    if not map:owns_pos(m.x, m.y) then
        return false, "pos not in this shard"
    end
    -- P3: 如果是 defender 且 battle 被锁定（attacker 在 handoff），拒绝本次 handoff
    if m.role == "defender" and m.battle_id then
        local battle_lock_key = "handoff_lock:" .. m.battle_id
        if not M.acquire_lock(battle_lock_key) then
            return false, "battle handoff in progress"
        end
        M.release_lock(battle_lock_key)
    end
    m.shard_id = map.shard_id
    if m.role == "attacker" then
        m.host_shard_id = map.shard_id
    end
    ctx.marches[m.uid] = m
    index_player_march(m.owner_player_id, m.uid)
    local ok, err = attach_march_aoi(map, m)
    if not ok then
        ctx.marches[m.uid] = nil
        unindex_player_march(m.owner_player_id, m.uid)
        return false, err or "enter scene failed"
    end
    if snap.battle then
        snap.battle.host_shard = map.shard_id
        ctx.field_battles[snap.battle.id] = snap.battle
        if snap.battle.defender_shard ~= map.shard_id then
            local addr = shard.addr(map.map_id, snap.battle.defender_shard)
            if addr then
                skynet.send(addr, "lua", "march_update_host", snap.battle.defender_uid, snap.battle.id, map.shard_id)
            end
        else
            local def = ctx.marches[snap.battle.defender_uid]
            if def then
                def.host_shard_id = map.shard_id
            end
        end
    elseif m.role == "defender" and m.battle_id and m.host_shard_id then
        local addr = shard.addr(map.map_id, m.host_shard_id)
        if addr then
            skynet.send(addr, "lua", "battle_defender_moved", m.battle_id, map.shard_id, m.uid)
        end
    end
    remember_owner_march(m.owner_player_id, m.uid, map.shard_id, false)
    notify_march_sync(map, m, false)
    return true, helpers.with_shard(map, {
        march_uid = m.uid,
        x = math.floor(m.x + 0.5),
        y = math.floor(m.y + 0.5),
        shard_id = map.shard_id,
    })
end

return M
