-- 大地图交互：锁、拾取、旧副本回写、跨片 try_*
-- 打野已改为行军到点结算，见 march_battle.march_attack_monster（CMD.interact_monster 已转发）。
local skynet = require "skynet"
local log = require "log"
local protocol_handler = require "protocol_handler"
local shard = require "map.shard"
local service_ctx = require "runtime.service_ctx"
local view = require "map.view_sync"
local helpers = require "map.helpers"
local rpc = require "cluster.rpc"

local ctx = service_ctx.get("map.shard_service", {})
local M = {}

ctx.obj_locks = ctx.obj_locks or {}
ctx.player_battles = ctx.player_battles or {}
ctx.remote_battles = ctx.remote_battles or {}
ctx.BATTLE_TIMEOUT_TICK = 1800
ctx.MAP_ATTACK_RANGE = 100

-- 锁：200 tick（2s）内同一目标只能一个玩家交互，防并发抢怪/抢拾取
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

function M.cleanup_expired_locks()
    local now = skynet.now()
    for lock_key, expire_at in pairs(ctx.obj_locks) do
        if (tonumber(expire_at) or 0) <= now then
            ctx.obj_locks[lock_key] = nil
        end
    end
end

-- 战斗锁：BATTLE_TIMEOUT_TICK（18s）超时自动释放，防玩家卡死导致目标永远锁死
function M.hold_lock(lock_key)
    if not lock_key then
        return
    end
    ctx.obj_locks[lock_key] = skynet.now() + ctx.BATTLE_TIMEOUT_TICK
end

function M.cancel_owner_battle(map, player_id, owner_shard_id, monster_uid)
    if not map or owner_shard_id == nil or owner_shard_id == map.shard_id then
        return
    end
    local addr = shard.addr(map.map_id, owner_shard_id)
    if addr then
        skynet.send(addr, "lua", "cancel_remote_battle", player_id, monster_uid)
    end
end

function M.cleanup_stale_battles()
    local now = skynet.now()
    local map = ctx.map
    for player_id, battle in pairs(ctx.player_battles) do
        local deadline = tonumber(battle and battle.deadline_tick) or 0
        if deadline > 0 and deadline <= now then
            if battle.owner_shard_id ~= nil and map and battle.owner_shard_id ~= map.shard_id then
                local addr = shard.addr(map.map_id, battle.owner_shard_id)
                if addr then
                    skynet.send(addr, "lua", "cancel_remote_battle", player_id, battle.monster_uid)
                end
            elseif battle.lock_key then
                M.release_lock(battle.lock_key)
            end
            ctx.player_battles[player_id] = nil
            log.warning("map battle timeout cleanup, player_id=%s, monster_uid=%s",
                tostring(player_id), tostring(battle.monster_uid))
        end
    end
    for player_id, battle in pairs(ctx.remote_battles) do
        local deadline = tonumber(battle and battle.deadline_tick) or 0
        if deadline > 0 and deadline <= now then
            if battle.lock_key then
                M.release_lock(battle.lock_key)
            end
            ctx.remote_battles[player_id] = nil
            log.warning("map remote battle timeout cleanup, player_id=%s, monster_uid=%s",
                tostring(player_id), tostring(battle.monster_uid))
        end
    end
end

local function in_attack_range(x1, y1, x2, y2, range)
    range = tonumber(range) or ctx.MAP_ATTACK_RANGE
    local dx = (tonumber(x1) or 0) - (tonumber(x2) or 0)
    local dy = (tonumber(y1) or 0) - (tonumber(y2) or 0)
    return (dx * dx + dy * dy) <= (range * range)
end

-- 攻击锚点 = 主城坐标（权威是主城实体；本片没有则全图问一遍，低频操作可接受）
local function resolve_city_pos(map, player_id)
    local city = map and map:get_city(player_id)
    if city then
        return city.x, city.y
    end
    for _, sid in ipairs(shard.all_ids()) do
        if map and sid ~= map.shard_id then
            local addr = shard.addr(map.map_id, sid)
            if addr then
                local ok, info = skynet.call(addr, "lua", "find_city", player_id)
                if ok and type(info) == "table" then
                    return tonumber(info.x), tonumber(info.y)
                end
            end
        end
    end
    return nil
end

local function start_monster_instance(map, player_id, uid)
    local instanceS = rpc.named_addr(".instance")
    if not instanceS then
        return false, "instance service unavailable"
    end
    return skynet.call(instanceS, "lua", "play_start_direct", player_id, "single", {
        instance_type_name = "single",
        inst_no = 1,
        ready_mode = "auto",
        mode_type = "survival",
        mode_config = {
            target_seconds = 180,
        },
        join_data = {
            source = "map_monster",
            map_id = map.map_id,
            shard_id = map.shard_id,
            monster_uid = uid,
        },
    })
end

local function notify_monster_removed(map_id, monster_uid, x, y, killer_player_id)
    local player_ids = helpers.get_players_in_map(map_id)
    if #player_ids == 0 then
        return
    end
    protocol_handler.send_to_players(player_ids, "map_monster_removed_notify", {
        map_id = map_id,
        monster_uid = monster_uid,
        x = x or 0,
        y = y or 0,
        killer_player_id = killer_player_id or 0,
    })
end

local function notify_item_removed(map_id, item_uid, x, y, picker_player_id)
    local player_ids = helpers.get_players_in_map(map_id)
    if #player_ids == 0 then
        return
    end
    protocol_handler.send_to_players(player_ids, "map_item_removed_notify", {
        map_id = map_id,
        item_uid = item_uid,
        x = x or 0,
        y = y or 0,
        picker_player_id = picker_player_id or 0,
    })
end

local function can_interact_obj(st, map, obj)
    if not st or not obj then
        return false, "invalid state or obj"
    end
    local owner_id = obj.owner_player_id or 0
    if owner_id ~= 0 and owner_id ~= st.player_id then
        return false, "obj not owned by player"
    end
    return true
end

-- 本地怪：直接锁 + 开副本；跨片怪：先问 owner shard，再逐个邻居问
function M.interact_monster(player_id, monster_uid)
    M.cleanup_expired_locks()
    M.cleanup_stale_battles()
    local st = helpers.get_or_init_player_state(player_id)
    local map = helpers.current_map(st)
    if not map then
        return false, "player not in map"
    end

    local uid = tostring(monster_uid or "")
    if uid == "" then
        return false, "monster_uid is required"
    end
    if ctx.player_battles[player_id] then
        return false, "battle already in progress"
    end
    -- 攻击范围锚定主城坐标，与镜头位置无关
    local ax, ay = resolve_city_pos(map, player_id)
    if not ax then
        return false, "主城不存在"
    end
    local monster = map:get_public_monster(uid)
    if monster then
        local can_interact, why = can_interact_obj(st, map, monster)
        if not can_interact then
            return false, why
        end
        if not monster.alive then
            return false, "monster already defeated"
        end
        if not in_attack_range(ax, ay, monster.x, monster.y, ctx.MAP_ATTACK_RANGE) then
            return false, "超出攻击范围"
        end
        local lock_key = "monster:" .. tostring(map.map_id) .. ":" .. uid
        if not M.acquire_lock(lock_key) then
            return false, "monster is busy"
        end
        M.hold_lock(lock_key)

        local ok, result_or_err = start_monster_instance(map, player_id, uid)
        if not ok then
            M.release_lock(lock_key)
            return false, result_or_err or "start monster instance failed"
        end

        ctx.player_battles[player_id] = {
            map_id = map.map_id,
            monster_uid = uid,
            lock_key = lock_key,
            inst_id = result_or_err.inst_id,
            start_tick = skynet.now(),
            deadline_tick = skynet.now() + ctx.BATTLE_TIMEOUT_TICK,
        }

        return true, helpers.with_shard(map, {
            map_id = map.map_id,
            monster_uid = uid,
            battle_type = "monster_instance",
            inst_id = result_or_err.inst_id or "",
            scene_id = result_or_err.scene_id or 0,
            result = "accepted",
        })
    end

    local ghost = map:get_obj(uid)
    local owner_shard_id = ghost and tonumber(ghost.shard_id)
    local req = {
        player_id = player_id,
        x = ax,
        y = ay,
        attack_range = ctx.MAP_ATTACK_RANGE,
    }
    local function accept_remote(nid, result)
        ctx.player_battles[player_id] = {
            map_id = map.map_id,
            monster_uid = uid,
            lock_key = nil,
            owner_shard_id = result.shard_id or nid,
            inst_id = result.inst_id,
            start_tick = skynet.now(),
            deadline_tick = skynet.now() + ctx.BATTLE_TIMEOUT_TICK,
            remote = true,
        }
        return true, result
    end
    local function call_owner(nid)
        local addr = shard.addr(map.map_id, nid)
        if not addr then
            return false, "目标战区不可用"
        end
        return skynet.call(addr, "lua", "try_interact_public", uid, req)
    end
    local tried = {}
    if owner_shard_id ~= nil and owner_shard_id ~= map.shard_id then
        tried[owner_shard_id] = true
        local ok, result = call_owner(owner_shard_id)
        if ok then
            return accept_remote(owner_shard_id, result)
        elseif result ~= "monster not found" and result ~= "map not found" then
            return false, result
        end
    end
    for _, nid in ipairs(map:neighbor_ids()) do
        if not tried[nid] then
            tried[nid] = true
            local ok, result = call_owner(nid)
            if ok then
                return accept_remote(nid, result)
            elseif result ~= "monster not found" and result ~= "map not found" then
                return false, result
            end
        end
    end
    return false, "目标不在攻击范围"
end

-- 战斗结果回写：本地直接改状态，跨片通知 owner shard apply
function M.on_battle_result(player_id, monster_uid, win)
    M.cleanup_expired_locks()
    M.cleanup_stale_battles()
    local st = helpers.get_or_init_player_state(player_id)
    local uid = tostring(monster_uid or "")
    local battle = ctx.player_battles[player_id]
    if not battle then
        return false, "battle context not found"
    end
    if uid == "" then
        uid = battle.monster_uid
    end
    if uid ~= battle.monster_uid then
        if battle.remote then
            M.cancel_owner_battle(helpers.current_map(st), player_id, battle.owner_shard_id, battle.monster_uid)
        elseif battle.lock_key then
            M.release_lock(battle.lock_key)
        end
        ctx.player_battles[player_id] = nil
        return false, "monster uid mismatch"
    end

    if battle.remote and battle.owner_shard_id ~= nil then
        local map = helpers.current_map(st)
        local addr = map and shard.addr(map.map_id, battle.owner_shard_id)
        if not addr then
            ctx.player_battles[player_id] = nil
            return false, "目标战区不可用"
        end
        local ok, result = skynet.call(addr, "lua", "apply_battle_result", player_id, uid, win and true or false)
        ctx.player_battles[player_id] = nil
        if not ok then
            skynet.send(addr, "lua", "cancel_remote_battle", player_id, uid)
            return false, result
        end
        view.sync_diff(player_id, map, st)
        return true, result
    end

    local map = helpers.get_map(battle.map_id)
    local monster = map and map:get_public_monster(uid)
    if not monster then
        if battle.lock_key then
            M.release_lock(battle.lock_key)
        end
        ctx.player_battles[player_id] = nil
        return false, "monster not found"
    end

    if win then
        monster.alive = false
        aoi_object.mark_dirty(monster, "alive")
        if map then
            map:detach(monster)
            map:save(monster)
            notify_monster_removed(battle.map_id, uid, monster.x, monster.y, player_id)
        end
    end
    if battle.lock_key then
        M.release_lock(battle.lock_key)
    end
    ctx.player_battles[player_id] = nil

    return true, helpers.with_shard(map, {
        map_id = battle.map_id or st.current_map_id,
        monster_uid = uid,
        win = win and true or false,
        removed = win and true or false,
    })
end

-- 跨片拾取：本地没有则逐个邻居问 try_pick_public
function M.pick_item(player_id, item_uid)
    M.cleanup_expired_locks()
    local st = helpers.get_or_init_player_state(player_id)
    local map = helpers.current_map(st)
    if not map then
        return false, "player not in map"
    end
    local uid = tostring(item_uid or "")
    if uid == "" then
        return false, "item_uid is required"
    end
    local public_resources = map.public_resources or {}
    local resource = public_resources[uid]
    if not resource then
        local req = {
            player_id = player_id,
        }
        for _, nid in ipairs(map:neighbor_ids()) do
            local addr = shard.addr(map.map_id, nid)
            if addr then
                local ok, result = skynet.call(addr, "lua", "try_pick_public", uid, req)
                if ok then
                    view.sync_diff(player_id, map, st)
                    return true, result
                elseif result ~= "item not found" and result ~= "map not found" then
                    return false, result
                end
            end
        end
        return false, "item not found"
    end
    local can_interact, why = can_interact_obj(st, map, resource)
    if not can_interact then
        return false, why
    end
    if not resource.alive then
        return false, "item already picked"
    end
    if resource.gatherable ~= false then
        return false, "need march gather"
    end
    local lock_key = "resource:" .. tostring(map.map_id) .. ":" .. uid
    if not M.acquire_lock(lock_key) then
        return false, "item is busy"
    end
    resource.alive = false
    aoi_object.mark_dirty(resource, "alive")
    map:detach(resource)
    if not map.store_ephemeral then
        map:save(resource)
    end
    notify_item_removed(map.map_id, uid, resource.x, resource.y, player_id)
    M.release_lock(lock_key)
    return true, helpers.with_shard(map, {
        map_id = map.map_id,
        item_uid = uid,
        item_id = resource.item_id,
        count = resource.count,
        removed = true,
    })
end

function M.try_pick_public(uid, req)
    M.cleanup_expired_locks()
    local map = ctx.map
    if not map then
        return false, "map not found"
    end
    uid = tostring(uid or "")
    if uid == "" or type(req) ~= "table" then
        return false, "item not found"
    end
    local resource = map:get_public_resource(uid)
    if not resource then
        return false, "item not found"
    end
    local st = {
        player_id = req.player_id,
    }
    local can_interact, why = can_interact_obj(st, map, resource)
    if not can_interact then
        return false, why
    end
    if not resource.alive then
        return false, "item already picked"
    end
    if resource.gatherable ~= false then
        return false, "need march gather"
    end
    local lock_key = "resource:" .. tostring(map.map_id) .. ":" .. uid
    if not M.acquire_lock(lock_key) then
        return false, "item is busy"
    end
    resource.alive = false
    aoi_object.mark_dirty(resource, "alive")
    map:detach(resource)
    if not map.store_ephemeral then
        map:save(resource)
    end
    notify_item_removed(map.map_id, uid, resource.x, resource.y, req.player_id)
    M.release_lock(lock_key)
    return true, helpers.with_shard(map, {
        map_id = map.map_id,
        item_uid = uid,
        item_id = resource.item_id,
        count = resource.count,
        removed = true,
    })
end

function M.try_interact_public(uid, req)
    M.cleanup_expired_locks()
    M.cleanup_stale_battles()
    local map = ctx.map
    if not map then
        return false, "map not found"
    end
    uid = tostring(uid or "")
    if uid == "" or type(req) ~= "table" or not req.player_id then
        return false, "monster not found"
    end
    local player_id = req.player_id
    if ctx.remote_battles[player_id] or ctx.player_battles[player_id] then
        return false, "battle already in progress"
    end
    local monster = map:get_public_monster(uid)
    if not monster then
        return false, "monster not found"
    end
    local st = {
        player_id = player_id,
    }
    local can_interact, why = can_interact_obj(st, map, monster)
    if not can_interact then
        return false, why
    end
    if not monster.alive then
        return false, "monster already defeated"
    end
    local px, py = tonumber(req.x), tonumber(req.y)
    if not px or not py then
        px, py = resolve_city_pos(map, player_id)
    end
    if not px then
        return false, "缺少攻击锚点"
    end
    if not in_attack_range(px, py, monster.x, monster.y, req.attack_range or ctx.MAP_ATTACK_RANGE) then
        return false, "超出攻击范围"
    end
    local lock_key = "monster:" .. tostring(map.map_id) .. ":" .. uid
    if not M.acquire_lock(lock_key) then
        return false, "monster is busy"
    end
    M.hold_lock(lock_key)
    local ok, result_or_err = start_monster_instance(map, player_id, uid)
    if not ok then
        M.release_lock(lock_key)
        return false, result_or_err or "start monster instance failed"
    end
    ctx.remote_battles[player_id] = {
        map_id = map.map_id,
        monster_uid = uid,
        lock_key = lock_key,
        inst_id = result_or_err.inst_id,
        start_tick = skynet.now(),
        deadline_tick = skynet.now() + ctx.BATTLE_TIMEOUT_TICK,
    }
    return true, helpers.with_shard(map, {
        map_id = map.map_id,
        monster_uid = uid,
        battle_type = "monster_instance",
        inst_id = result_or_err.inst_id or "",
        scene_id = result_or_err.scene_id or 0,
        result = "accepted",
    })
end

-- owner shard 处理跨片战斗结果：改状态、通知、清锁
function M.apply_battle_result(player_id, monster_uid, win)
    M.cleanup_expired_locks()
    M.cleanup_stale_battles()
    local map = ctx.map
    if not map then
        return false, "map not found"
    end
    local uid = tostring(monster_uid or "")
    local battle = ctx.remote_battles[player_id]
    if not battle then
        return false, "battle context not found"
    end
    if uid == "" then
        uid = battle.monster_uid
    end
    if uid ~= battle.monster_uid then
        return false, "monster uid mismatch"
    end
    local monster = map:get_public_monster(uid)
    if not monster then
        if battle.lock_key then
            M.release_lock(battle.lock_key)
        end
        ctx.remote_battles[player_id] = nil
        return false, "monster not found"
    end
    if win then
        monster.alive = false
        aoi_object.mark_dirty(monster, "alive")
        map:detach(monster)
        map:save(monster)
        notify_monster_removed(map.map_id, uid, monster.x, monster.y, player_id)
        protocol_handler.send_to_player(player_id, "map_monster_removed_notify", {
            map_id = map.map_id,
            monster_uid = uid,
            x = monster.x or 0,
            y = monster.y or 0,
            killer_player_id = player_id or 0,
        })
    end
    if battle.lock_key then
        M.release_lock(battle.lock_key)
    end
    ctx.remote_battles[player_id] = nil
    return true, helpers.with_shard(map, {
        map_id = map.map_id,
        monster_uid = uid,
        win = win and true or false,
        removed = win and true or false,
    })
end

function M.cancel_remote_battle(player_id, monster_uid)
    local battle = ctx.remote_battles[player_id]
    if not battle then
        return true
    end
    if monster_uid and tostring(monster_uid) ~= "" and tostring(monster_uid) ~= tostring(battle.monster_uid) then
        return true
    end
    if battle.lock_key then
        M.release_lock(battle.lock_key)
    end
    ctx.remote_battles[player_id] = nil
    return true
end

return M
