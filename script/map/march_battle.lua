-- 行军战斗：到点计划、定时器一次结算、打野。
local skynet = require "skynet"
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
package.loaded["map.march_battle"] = M
local runtime = require "map.march_runtime"
local gather = require "map.march_gather"

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
        duration = extra.duration or battle.duration or 0,
        reason = extra.reason or "",
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
    m.battle_duration = 0
    aoi_object.mark_dirty(m, "battle_id")
    aoi_object.mark_dirty(m, "battle_duration")
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
    aoi_object.mark_dirty(m, "x")
    aoi_object.mark_dirty(m, "y")
    aoi_object.mark_dirty(m, "waypoints")
    aoi_object.mark_dirty(m, "wp_index")
end

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

local function battle_dps()
    return march.DAMAGE / march.TICK_SEC
end

local function battle_duration_of(atk_hp, def_hp)
    local dps = battle_dps()
    if dps <= 0 then
        return 0.01
    end
    local ta = (tonumber(atk_hp) or 0) / dps
    local td = (tonumber(def_hp) or 0) / dps
    local t = math.min(ta, td)
    if t < 0.01 then
        t = 0.01
    end
    return t
end

local function battle_remain_hp(hp0, elapsed)
    local remain = (tonumber(hp0) or 0) - battle_dps() * (tonumber(elapsed) or 0)
    if remain < 0 then
        remain = 0
    end
    return math.floor(remain + 1e-6)
end

local function freeze_march(m)
    if not m then
        return
    end
    m.waypoints = { { x = m.x, y = m.y } }
    m.wp_index = 2
    aoi_object.mark_dirty(m, "waypoints")
    aoi_object.mark_dirty(m, "wp_index")
    aoi_object.mark_dirty(m, "x")
    aoi_object.mark_dirty(m, "y")
end

local function apply_battle_plan_to_march(m, battle, role)
    if not m or not battle then
        return
    end
    m.battle_id = battle.id
    m.host_shard_id = battle.host_shard
    m.role = role
    m.state = march.STATE_BATTLE
    m.battle_duration = battle.duration
    freeze_march(m)
    aoi_object.mark_dirty(m, "state")
    aoi_object.mark_dirty(m, "battle_id")
    aoi_object.mark_dirty(m, "battle_duration")
end

local function sync_march_battle_aoi(map, m)
    if map and m and m.in_aoi then
        map:sync_ghosts(m)
        view.sync_obj_attr_around(map, m)
    end
end

local function local_monster(map, uid)
    if not map then
        return nil
    end
    return map.public_monsters and map.public_monsters[tostring(uid or "")]
end

local function pack_monster_snap(map, mon)
    if not mon then
        return nil
    end
    return {
        uid = mon.uid,
        x = mon.x,
        y = mon.y,
        hp = tonumber(mon.hp) or march.MAX_HP,
        max_hp = tonumber(mon.max_hp) or march.MAX_HP,
        battle_id = mon.battle_id or "",
        shard_id = map and map.shard_id,
        alive = mon.alive ~= false,
        kind = "monster",
        local_monster = mon,
    }
end

local function query_sid_monster(map, sid, uid)
    if not map or sid == nil or sid == map.shard_id then
        return nil
    end
    local addr = shard.addr(map.map_id, sid)
    if not addr then
        return nil
    end
    local ok, snap = skynet.call(addr, "lua", "query_monster", uid)
    if ok and type(snap) == "table" then
        snap.kind = "monster"
        return snap
    end
    return nil
end

local function resolve_monster(map, uid, hint_shard)
    uid = tostring(uid or "")
    if uid == "" or not map then
        return nil
    end
    local mon = local_monster(map, uid)
    if mon and mon.alive ~= false then
        return pack_monster_snap(map, mon)
    end
    local snap = query_sid_monster(map, hint_shard, uid)
    if snap then
        return snap
    end
    local ghost = map:get_obj(uid)
    if ghost and ghost.type == aoi_object.TYPE.MONSTER then
        snap = query_sid_monster(map, ghost.shard_id, uid)
        if snap then
            return snap
        end
        return {
            uid = uid,
            x = ghost.x,
            y = ghost.y,
            hp = tonumber(ghost.hp) or march.MAX_HP,
            max_hp = tonumber(ghost.max_hp) or march.MAX_HP,
            battle_id = ghost.battle_id or "",
            shard_id = tonumber(ghost.shard_id),
            kind = "monster",
        }
    end
    for _, sid in ipairs(shard.all_ids()) do
        snap = query_sid_monster(map, sid, uid)
        if snap then
            return snap
        end
    end
    return nil
end

local function kill_monster(map, mon, killer_id)
    if not map or not mon then
        return
    end
    mon.alive = false
    mon.hp = 0
    mon.battle_id = nil
    aoi_object.mark_dirty(mon, "hp")
    aoi_object.mark_dirty(mon, "battle_id")
    map:detach(mon)
    if mon._id then
        map:save(mon)
    end
    local player_ids = helpers.get_players_in_map(map.map_id)
    if #player_ids > 0 then
        protocol_handler.send_to_players(player_ids, "map_monster_removed_notify", {
            map_id = map.map_id,
            monster_uid = mon.uid,
            x = mon.x or 0,
            y = mon.y or 0,
            killer_player_id = killer_id or 0,
        })
    end
end

local function clear_monster_battle(map, mon)
    if not mon then
        return
    end
    mon.battle_id = nil
    aoi_object.mark_dirty(mon, "battle_id")
    if map and mon.in_aoi then
        map:sync_ghosts(mon)
        view.sync_obj_attr_around(map, mon)
    end
end

function M.schedule_battle_done(battle)
    if not battle then
        return
    end
    local seq = battle.seq or 0
    local id = battle.id
    local remain_tick = (tonumber(battle.battle_end) or skynet.now()) - skynet.now()
    if remain_tick < 1 then
        remain_tick = 1
    end
    skynet.timeout(remain_tick, function()
        local cur = ctx.field_battles[id]
        if not cur or cur.seq ~= seq then
            return
        end
        M.settle_battle(cur, "timeout")
    end)
end

local function start_battle(map, atk, target)
    if not atk or not target then
        return false, "invalid target"
    end
    if atk.battle_id then
        return false, "already in battle"
    end
    local kind = target.kind or "march"
    if target.battle_id and target.battle_id ~= "" then
        return false, "目标交战中"
    end
    if kind == "march" then
        local ao, to = atk.owner_player_id or 0, target.owner_player_id or 0
        if ao ~= 0 and ao == to then
            return false, "不能攻击自己的行军"
        end
    elseif kind == "monster" then
        if not target.local_monster then
            return false, "目标不在本战区"
        end
        if target.local_monster.alive == false then
            return false, "monster already defeated"
        end
    else
        return false, "invalid target"
    end
    local atk_hp0 = tonumber(atk.hp) or 0
    local def_hp0 = tonumber(target.hp) or 0
    local duration = battle_duration_of(atk_hp0, def_hp0)
    local now = skynet.now()
    local battle = {
        id = string.format("fb_%s_%d", atk.uid, now),
        kind = kind,
        attacker_uid = atk.uid,
        attacker_player_id = atk.owner_player_id,
        defender_uid = target.uid,
        defender_player_id = target.owner_player_id,
        defender_shard = target.shard_id or map.shard_id,
        host_shard = map.shard_id,
        atk_hp0 = atk_hp0,
        def_hp0 = def_hp0,
        duration = duration,
        battle_start = now,
        battle_end = now + math.max(1, math.floor(duration * 100 + 0.5)),
        seq = 1,
    }
    local def_local
    if kind == "march" then
        def_local = target.local_march or ctx.marches[target.uid]
        if def_local then
            if def_local.battle_id then
                return false, "目标交战中"
            end
            apply_battle_plan_to_march(def_local, battle, "defender")
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
                duration = duration,
            })
            if not ok then
                return false, err or "目标交战中"
            end
        end
    else
        local mon = target.local_monster
        mon.battle_id = battle.id
        aoi_object.mark_dirty(mon, "battle_id")
        aoi_object.mark_dirty(mon, "x")
        aoi_object.mark_dirty(mon, "y")
        if mon.in_aoi then
            map:sync_ghosts(mon)
            view.sync_obj_attr_around(map, mon)
        end
    end
    atk.intent = (kind == "monster") and march.INTENT_ATTACK_MONSTER or march.INTENT_ATTACK
    atk.target_uid = target.uid
    atk.target_shard_id = battle.defender_shard
    aoi_object.mark_dirty(atk, "intent")
    aoi_object.mark_dirty(atk, "target_uid")
    apply_battle_plan_to_march(atk, battle, "attacker")
    ctx.field_battles[battle.id] = battle
    sync_march_battle_aoi(map, atk)
    if def_local then
        sync_march_battle_aoi(map, def_local)
    end
    notify_field_battle(map, battle, "engage", {
        attacker_hp = atk_hp0,
        defender_hp = def_hp0,
        duration = duration,
    })
    M.schedule_battle_done(battle)
    return true
end

function M.settle_battle(battle, reason)
    if not battle or battle.settled then
        return
    end
    battle.settled = true
    battle.seq = (battle.seq or 0) + 1
    local map = ctx.map
    if ctx.field_battles[battle.id] then
        ctx.field_battles[battle.id] = nil
    end
    local elapsed
    if reason == "timeout" then
        elapsed = tonumber(battle.duration) or 0
    else
        local start_tick = tonumber(battle.battle_start) or skynet.now()
        elapsed = (skynet.now() - start_tick) / 100
        local cap = tonumber(battle.duration) or elapsed
        if elapsed > cap then
            elapsed = cap
        end
        if elapsed < 0 then
            elapsed = 0
        end
    end
    local atk_hp = battle_remain_hp(battle.atk_hp0, elapsed)
    local def_hp = battle_remain_hp(battle.def_hp0, elapsed)
    local atk_dead = atk_hp <= 0
    local def_dead = def_hp <= 0
    local atk = ctx.marches[battle.attacker_uid]
    if atk then
        atk.hp = atk_hp
        aoi_object.mark_dirty(atk, "hp")
    end
    local def = ctx.marches[battle.defender_uid]
    local mon
    if battle.kind == "monster" then
        mon = local_monster(map, battle.defender_uid)
        if mon then
            mon.hp = def_hp
            aoi_object.mark_dirty(mon, "hp")
        end
    elseif def then
        def.hp = def_hp
        aoi_object.mark_dirty(def, "hp")
    elseif map and battle.defender_shard ~= nil and battle.defender_shard ~= map.shard_id then
        local addr = shard.addr(map.map_id, battle.defender_shard)
        if addr then
            skynet.call(addr, "lua", "settle_defender", battle.defender_uid, {
                battle_id = battle.id,
                hp = def_hp,
                dead = def_dead,
            })
        end
    end
    notify_field_battle(map, battle, "end", {
        attacker_hp = atk_hp,
        defender_hp = def_hp,
        duration = battle.duration or 0,
        reason = reason or "",
    })
    if atk then
        clear_march_battle_fields(atk, false)
        sync_march_battle_aoi(map, atk)
    end
    if def then
        if def_dead then
            def.alive = false
        else
            clear_march_battle_fields(def, false)
            sync_march_battle_aoi(map, def)
        end
    end
    if mon then
        if def_dead then
            kill_monster(map, mon, battle.attacker_player_id)
        else
            map_store.mark_dirty(mon)
            clear_monster_battle(map, mon)
        end
    end
    if atk_dead and atk then
        atk.alive = false
        runtime.despawn_march(map, atk, "dead", true)
    elseif atk and not atk_dead and battle.kind == "monster" and def_dead then
        gather.begin_return(map, atk)
    end
    if def_dead and def and ctx.marches[def.uid] then
        runtime.despawn_march(map, def, "dead", true)
    end
end

function M.end_field_battle(battle, reason)
    M.settle_battle(battle, reason or "end")
end

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
    local path = runtime.find_map_path(map, m.x, m.y, tgt.x, tgt.y, true)
    if path then
        runtime.apply_march_path(m, path, tgt.x, tgt.y)
        runtime.broadcast_plan(map, m)
    end
end

function M.try_engage_chase(map, m)
    local tgt
    if m.intent == march.INTENT_ATTACK_MONSTER then
        tgt = resolve_monster(map, m.target_uid, m.target_shard_id)
    else
        tgt = resolve_target(map, m.target_uid, m.target_shard_id)
        if tgt then
            tgt.kind = tgt.kind or "march"
        end
    end
    if not tgt then
        return false
    end
    m.target_shard_id = tgt.shard_id
    if not m.battle_id and march.in_range(m.x, m.y, tgt.x, tgt.y, march.ENGAGE_RANGE) then
        local ok = start_battle(map, m, tgt)
        if ok and m.battle_id then
            return true
        end
        if m.intent == march.INTENT_ATTACK_MONSTER and tgt.local_monster then
            gather.begin_return(map, m)
        end
        return false
    end
    maybe_repath_chase(map, m, tgt)
    return false
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
    local m = runtime.pick_player_march(player_id, march_uid)
    if not m then
        return false, "march not found"
    end
    if m.battle_id then
        return false, "already in battle"
    end
    if m.state == march.STATE_GATHERING or m.intent == march.INTENT_GATHER then
        gather.settle_gather_progress(map, m)
        gather.release_occupy(map, m)
    end
    if m.uid == target_uid then
        return false, "不能攻击自己的行军"
    end
    local tgt = resolve_target(map, target_uid, m.target_shard_id)
    local intent = march.INTENT_ATTACK
    if tgt then
        tgt.kind = "march"
        if tgt.owner_player_id == player_id then
            return false, "不能攻击自己的行军"
        end
    else
        tgt = resolve_monster(map, target_uid, m.target_shard_id)
        intent = march.INTENT_ATTACK_MONSTER
        if not tgt then
            return false, "目标不在范围内"
        end
    end
    m.intent = intent
    m.target_uid = target_uid
    m.target_shard_id = tgt.shard_id
    m.state = march.STATE_CHASE
    aoi_object.mark_dirty(m, "intent")
    aoi_object.mark_dirty(m, "target_uid")
    aoi_object.mark_dirty(m, "state")
    if march.in_range(m.x, m.y, tgt.x, tgt.y, march.ENGAGE_RANGE) then
        local ok, err = start_battle(map, m, tgt)
        if not ok then
            return false, err
        end
    else
        local path, path_err = runtime.find_map_path(map, m.x, m.y, tgt.x, tgt.y, true)
        if path then
            runtime.apply_march_path(m, path, tgt.x, tgt.y)
        else
            return false, path_err or "无法到达目标"
        end
    end
    runtime.notify_march_sync(map, m)
    runtime.sync_march_aoi(map, m, true, true)
    return true, helpers.with_shard(map, {
        march_uid = m.uid,
        target_uid = target_uid,
        state = m.state,
        battle_id = m.battle_id or "",
    })
end

function M.engage(atk_uid, def_uid)
    local map = ctx.map
    if not map then
        return false, "map not found"
    end
    local atk = ctx.marches[tostring(atk_uid or "")]
    if not atk or not atk.alive then
        return false, "attacker not found"
    end
    def_uid = tostring(def_uid or "")
    if def_uid == "" or def_uid == atk.uid then
        return false, "invalid target"
    end
    local tgt = resolve_target(map, def_uid, atk.target_shard_id)
    if not tgt then
        return false, "目标不在范围内"
    end
    atk.intent = march.INTENT_ATTACK
    atk.target_uid = def_uid
    atk.target_shard_id = tgt.shard_id
    aoi_object.mark_dirty(atk, "intent")
    aoi_object.mark_dirty(atk, "target_uid")
    if not atk.battle_id then
        atk.state = march.STATE_CHASE
        aoi_object.mark_dirty(atk, "state")
        tgt.kind = tgt.kind or "march"
        if march.in_range(atk.x, atk.y, tgt.x, tgt.y, march.ENGAGE_RANGE) then
            local ok, err = start_battle(map, atk, tgt)
            if not ok then
                return false, err
            end
        else
            local path = runtime.find_map_path(map, atk.x, atk.y, tgt.x, tgt.y, true)
            if path then
                runtime.apply_march_path(atk, path, tgt.x, tgt.y)
            end
        end
    end
    runtime.notify_march_sync(map, atk)
    runtime.sync_march_aoi(map, atk, true, true)
    return true
end

function M.query_monster(uid)
    local map = ctx.map
    uid = tostring(uid or "")
    local mon = local_monster(map, uid)
    if not mon or mon.alive == false then
        return false, "monster not found"
    end
    local snap = pack_monster_snap(map, mon)
    snap.local_monster = nil
    return true, snap
end

function M.march_attack_monster(player_id, monster_uid)
    local map = ctx.map
    if not map then
        return false, "map not found"
    end
    local city = map:get_city(player_id)
    if not city then
        return false, "主城不在本战区"
    end
    monster_uid = tostring(monster_uid or "")
    if monster_uid == "" then
        return false, "monster_uid is required"
    end
    local snap = resolve_monster(map, monster_uid)
    if not snap then
        return false, "monster not found"
    end
    if (snap.battle_id or "") ~= "" then
        return false, "monster is busy"
    end
    if runtime.count_all_player_marches(player_id) >= march.MAX_PER_PLAYER then
        return false, "行军数量已满"
    end
    local tx, ty = march.clamp(map.def, snap.x, snap.y)
    local path, path_err = runtime.find_map_path(map, city.x, city.y, tx, ty, true)
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
        state = march.STATE_CHASE,
        last_path_tx = dest.x,
        last_path_ty = dest.y,
        intent = march.INTENT_ATTACK_MONSTER,
        target_uid = monster_uid,
        target_shard_id = snap.shard_id,
    })
    aoi_object.mark_dirty(m, "intent")
    aoi_object.mark_dirty(m, "target_uid")
    aoi_object.mark_dirty(m, "state")
    ctx.marches[uid] = m
    runtime.index_player_march(player_id, uid)
    local ok, err = runtime.attach_march_aoi(map, m)
    if not ok then
        ctx.marches[uid] = nil
        runtime.unindex_player_march(player_id, uid)
        return false, err or "行军进入场景失败"
    end
    runtime.remember_owner_march(player_id, uid, map.shard_id, false)
    runtime.notify_march_sync(map, m)
    runtime.sync_march_aoi(map, m, true, true)
    return true, helpers.with_shard(map, {
        map_id = map.map_id,
        monster_uid = monster_uid,
        march_uid = uid,
        battle_type = "march",
        inst_id = "",
        scene_id = 0,
        result = "accepted",
        x = math.floor(m.x + 0.5),
        y = math.floor(m.y + 0.5),
        dest_x = math.floor(dest.x + 0.5),
        dest_y = math.floor(dest.y + 0.5),
        hp = m.hp,
        max_hp = m.max_hp,
        state = m.state,
        intent = m.intent,
    })
end

function M.settle_defender(uid, info)
    local map = ctx.map
    local m = ctx.marches[tostring(uid or "")]
    if not m then
        return false, "march not found"
    end
    info = info or {}
    if info.battle_id and m.battle_id and tostring(info.battle_id) ~= tostring(m.battle_id) then
        return false, "battle mismatch"
    end
    m.hp = math.max(0, tonumber(info.hp) or m.hp or 0)
    aoi_object.mark_dirty(m, "hp")
    if info.dead or m.hp <= 0 then
        m.alive = false
        runtime.despawn_march(map, m, "dead", true)
        return true, { hp = 0, dead = true }
    end
    clear_march_battle_fields(m, false)
    runtime.notify_march_sync(map, m)
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
    m.battle_duration = tonumber(info.duration) or 0
    freeze_march(m)
    aoi_object.mark_dirty(m, "state")
    aoi_object.mark_dirty(m, "battle_id")
    aoi_object.mark_dirty(m, "battle_duration")
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
        M.end_field_battle(battle, reason or "remote_end")
    end
    return true
end

return M
