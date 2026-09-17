-- 大世界行军运行时：索引、AOI、寻路、跨片、tick、出发/取消。
-- 采集 / 战斗是独立模块：map.march_gather、map.march_battle。
local skynet = require "skynet"
local log = require "log"
local protocol_handler = require "protocol_handler"
local shard = require "map.shard"
local march = require "map.march"
local aoi_object = require "map.aoi_object"
local service_ctx = require "runtime.service_ctx"
local view = require "map.view_sync"
local helpers = require "map.helpers"

local ctx = service_ctx.get("map.shard_service", {})
local M = {}
package.loaded["map.march_runtime"] = M
local gather, battle

ctx.marches = ctx.marches or {}
ctx.player_marches = ctx.player_marches or {}
ctx.field_battles = ctx.field_battles or {}
ctx.march_seq = ctx.march_seq or {}
ctx.obj_locks = ctx.obj_locks or {}
ctx.CHASE_REPATH_DIST = 32
ctx.PATHFINDING_NAME = ".pathfinding"

function M.acquire_lock(lock_key)
    local now = skynet.now()
    local expire_at = ctx.obj_locks[lock_key]
    if expire_at and expire_at > now then
        return false
    end
    ctx.obj_locks[lock_key] = now + 200
    return true
end

function M.release_lock(lock_key)
    ctx.obj_locks[lock_key] = nil
end

function M.index_player_march(player_id, uid)
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

function M.unindex_player_march(player_id, uid)
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

function M.count_all_player_marches(player_id)
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

function M.pick_player_march(player_id, march_uid)
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

function M.remember_owner_march(player_id, uid, shard_id, removed)
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

function M.notify_march_sync(map, m, removed)
    if not m then
        return
    end
    local payload = {
        map_id = map and map.map_id or 0,
        marches = (not removed) and { march.pack_visible(m, true) } or {},
        removed_uid = removed and (m.uid or "") or "",
    }
    if m.owner_player_id then
        protocol_handler.send_to_player(m.owner_player_id, "map_march_sync_notify", payload)
    end
end

function M.despawn_march(map, m, reason, skip_end_battle)
    if not m then
        return
    end
    gather.settle_gather_progress(map, m)
    gather.release_occupy(map, m)
    if not skip_end_battle and m.battle_id then
        local battle_obj = ctx.field_battles[m.battle_id]
        if battle_obj then
            battle.settle_battle(battle_obj, reason or "despawn")
            if not ctx.marches[m.uid] then
                return
            end
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
    M.unindex_player_march(m.owner_player_id, m.uid)
    M.remember_owner_march(m.owner_player_id, m.uid, map and map.shard_id, true)
    M.notify_march_sync(map, m, true)
end

function M.attach_march_aoi(map, m)
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

function M.sync_march_aoi(map, m, force_notify, is_new_action)
    local ix = math.floor((m.x or 0) + 0.5)
    local iy = math.floor((m.y or 0) + 0.5)
    local obj = map:get_obj(m.uid)
    local old_x = obj and obj._aoi_x or m.x
    local old_y = obj and obj._aoi_y or m.y
    if m.in_aoi and (ix ~= old_x or iy ~= old_y) then
        map:move_obj(m.uid, ix, iy)
        if not march.DEAD_RECKONING then
            aoi_object.mark_dirty(m, "x")
            aoi_object.mark_dirty(m, "y")
            if is_new_action then
                view.sync_obj_attr_around(map, m)
            else
                view.sync_obj_move_around(map, m)
            end
        end
    elseif m.in_aoi then
        map:sync_ghosts(m)
    end
    if march.DEAD_RECKONING and is_new_action and m.in_aoi then
        map:sync_ghosts(m)
        view.sync_obj_attr_around(map, m)
    end
    if force_notify or march.dist2(m.x, m.y, m.last_notify_x, m.last_notify_y) >= (march.NOTIFY_MOVE * march.NOTIFY_MOVE) then
        m.last_notify_x, m.last_notify_y = m.x, m.y
        M.notify_march_sync(map, m)
        if not march.DEAD_RECKONING and m.in_aoi then
            view.sync_obj_attr_around(map, m)
        end
    end
end

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
    local battle_lock_key = nil
    if m.role == "attacker" and m.battle_id then
        battle_lock_key = "handoff_lock:" .. m.battle_id
        if not M.acquire_lock(battle_lock_key) then
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
    M.unindex_player_march(m.owner_player_id, m.uid)
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
        M.index_player_march(m.owner_player_id, m.uid)
        if snap.battle then
            ctx.field_battles[snap.battle.id] = snap.battle
        end
        M.attach_march_aoi(map, m)
        log.error("march handoff failed, uid=%s dest=%s err=%s", tostring(m.uid), tostring(dest), tostring(result))
        if battle_lock_key then
            M.release_lock(battle_lock_key)
        end
        return false
    end
    if battle_lock_key then
        M.release_lock(battle_lock_key)
    end
    M.remember_owner_march(m.owner_player_id, m.uid, dest, false)
    return true
end

function M.find_map_path(map, x1, y1, x2, y2, keep_end)
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

function M.apply_march_path(m, path, tx, ty)
    march.set_path(m, path)
    m.last_path_tx = tx
    m.last_path_ty = ty
    aoi_object.mark_dirty(m, "waypoints")
    aoi_object.mark_dirty(m, "wp_index")
    aoi_object.mark_dirty(m, "x")
    aoi_object.mark_dirty(m, "y")
end

function M.broadcast_plan(map, m)
    aoi_object.mark_dirty(m, "waypoints")
    aoi_object.mark_dirty(m, "wp_index")
    aoi_object.mark_dirty(m, "x")
    aoi_object.mark_dirty(m, "y")
    if not m.in_aoi then
        return
    end
    map:sync_ghosts(m)
    view.sync_obj_attr_around(map, m)
end

function M.find_owner_city(map, player_id)
    if not map or not player_id then
        return nil
    end
    local city = map:get_city(player_id)
    if city then
        return city
    end
    for _, sid in ipairs(shard.all_ids()) do
        if sid ~= map.shard_id then
            local addr = shard.addr(map.map_id, sid)
            if addr then
                local ok, info = skynet.call(addr, "lua", "find_city", player_id)
                if ok and type(info) == "table" then
                    return {
                        uid = info.uid,
                        x = tonumber(info.x),
                        y = tonumber(info.y),
                        shard_id = info.shard_id,
                    }
                end
            end
        end
    end
    return nil
end

gather = require "map.march_gather"
battle = require "map.march_battle"

local function march_path_done(m)
    return not (m.waypoints and m.waypoints[m.wp_index or 1])
end

local function on_march_arrived(map, m)
    if m.intent == march.INTENT_GATHER then
        gather.begin_gather(map, m)
    elseif m.intent == march.INTENT_RETURN then
        gather.finish_return(map, m)
    elseif m.intent == march.INTENT_ATTACK or m.intent == march.INTENT_ATTACK_MONSTER then
        m.state = march.STATE_CHASE
        aoi_object.mark_dirty(m, "state")
        battle.try_engage_chase(map, m)
    end
end

local function tick_one_march(map, m)
    local hold = m.state == march.STATE_BATTLE or m.state == march.STATE_GATHERING
    if m.state == march.STATE_CHASE and not m.battle_id then
        if battle.try_engage_chase(map, m) then
            hold = true
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
    if (m.state == march.STATE_MARCHING or m.state == march.STATE_CHASE)
        and not m.battle_id and march_path_done(m) then
        on_march_arrived(map, m)
        if not ctx.marches[m.uid] then
            return
        end
    end
    M.sync_march_aoi(map, m, false, false)
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
            M.despawn_march(map, m, "leave")
        end
    end
    ctx.player_marches[player_id] = nil
end

function M.march_start(player_id, x, y)
    local map = ctx.map
    if not map then
        return false, "map not found"
    end
    local city = map:get_city(player_id)
    if not city then
        return false, "主城不在本战区"
    end
    if M.count_all_player_marches(player_id) >= march.MAX_PER_PLAYER then
        return false, "行军数量已满"
    end
    x, y = march.clamp(map.def, x, y)
    local path, path_err = M.find_map_path(map, city.x, city.y, x, y)
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
        intent = march.INTENT_MOVE,
    })
    ctx.marches[uid] = m
    M.index_player_march(player_id, uid)
    local ok, err = M.attach_march_aoi(map, m)
    if not ok then
        ctx.marches[uid] = nil
        M.unindex_player_march(player_id, uid)
        return false, err or "行军进入场景失败"
    end
    M.remember_owner_march(player_id, uid, map.shard_id, false)
    M.notify_march_sync(map, m)
    M.sync_march_aoi(map, m, true, true)
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

function M.march_cancel(player_id, march_uid)
    local map = ctx.map
    local m = M.pick_player_march(player_id, march_uid)
    if not m then
        return false, "march not found"
    end
    local uid = m.uid
    if m.battle_id then
        local battle_obj = ctx.field_battles[m.battle_id]
        if battle_obj then
            battle.settle_battle(battle_obj, "cancel")
        elseif m.host_shard_id and map and m.host_shard_id ~= map.shard_id then
            local addr = shard.addr(map.map_id, m.host_shard_id)
            if addr then
                skynet.send(addr, "lua", "end_hosted_battle", m.battle_id, "cancel")
            end
            return true, helpers.with_shard(map, {
                march_uid = uid,
                removed = false,
            })
        end
        m = ctx.marches[uid]
        if not m then
            return true, helpers.with_shard(map, {
                march_uid = uid,
                removed = true,
            })
        end
    end
    if m.state == march.STATE_GATHERING or (tonumber(m.cargo_count) or 0) > 0 then
        if m.intent == march.INTENT_RETURN then
            return true, helpers.with_shard(map, {
                march_uid = uid,
                removed = false,
            })
        end
        gather.begin_return(map, m)
        return true, helpers.with_shard(map, {
            march_uid = uid,
            removed = false,
        })
    end
    M.despawn_march(map, m, "cancel")
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
    M.index_player_march(m.owner_player_id, m.uid)
    local ok, err = M.attach_march_aoi(map, m)
    if not ok then
        ctx.marches[m.uid] = nil
        M.unindex_player_march(m.owner_player_id, m.uid)
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
    M.remember_owner_march(m.owner_player_id, m.uid, map.shard_id, false)
    M.notify_march_sync(map, m, false)
    if m.state == march.STATE_GATHERING and (tonumber(m.gather_amount) or 0) > 0 then
        gather.schedule_gather_done(map, m)
    end
    if snap.battle then
        battle.schedule_battle_done(snap.battle)
    end
    return true, helpers.with_shard(map, {
        march_uid = m.uid,
        x = math.floor(m.x + 0.5),
        y = math.floor(m.y + 0.5),
        shard_id = map.shard_id,
    })
end

return M
