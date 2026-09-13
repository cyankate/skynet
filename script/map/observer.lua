-- 大地图观察者：进图 / 移动 / 跨片 / 离图 / 状态
local skynet = require "skynet"
local log = require "log"
local map_store = require "map.map_store"
local shard = require "map.shard"
local aoi_object = require "map.aoi_object"
local service_ctx = require "runtime.service_ctx"
local view = require "map.view_sync"
local helpers = require "map.helpers"
local interact = require "map.interact"
local march_runtime = require "map.march_runtime"

local ctx = service_ctx.get("map.map_service", {})
local M = {}

ctx.player_state = ctx.player_state or {}
ctx.MAP_VIEW_RANGE = 100

function M.enter_map(player_id, player_name, map_id)
    local map = helpers.get_map(map_id)
    if not map then
        return false, "map not found"
    end

    local st = helpers.get_or_init_player_state(player_id)
    st.player_id = player_id
    local old_map_id = st.current_map_id or 0
    local old_map = helpers.get_map(old_map_id)
    if st.current_scene_id and st.current_scene_id > 0 and old_map then
        pcall(function()
            old_map:leave_obj(player_id)
        end)
    end

    st.player_name = player_name or st.player_name or ("Player_" .. tostring(player_id))
    local start = map.def.start or {}
    local x, y
    if start.x and start.y and map:owns_pos(start.x, start.y) then
        x, y = start.x, start.y
    else
        x, y = map:rand_spawn()
    end
    local observer = aoi_object.Observer.new({
        uid = player_id,
        player_id = player_id,
        player_name = st.player_name,
        x = x,
        y = y,
        view_range = ctx.MAP_VIEW_RANGE,
        map_id = map_id,
        shard_id = map.shard_id,
        owner_shard_id = map.shard_id,
        is_ghost = false,
    })
    local enter_ok, enter_err = map:enter_obj(observer)
    if not enter_ok then
        return false, enter_err or "enter aoi failed"
    end

    st.current_map_id = map_id
    st.current_scene_id = map_id
    st.x = x
    st.y = y
    local monsters, items, marches, buildings = view.collect_visible(map, st)
    view.sync_view(player_id, map, st)

    return true, helpers.with_shard(map, {
        map_id = map_id,
        scene_id = map_id,
        x = x,
        y = y,
        monsters = monsters,
        items = items,
        marches = marches,
        buildings = buildings,
    })
end

function M.move(player_id, x, y)
    local st = helpers.get_or_init_player_state(player_id)
    local map = helpers.current_map(st)
    if not map or not st.current_scene_id or st.current_scene_id <= 0 then
        return false, "player not in map"
    end
    local dest_shard = shard.shard_id_of_pos(x, y, map.def)
    if dest_shard ~= map.shard_id then
        return M.transfer_observer(player_id, dest_shard, x, y)
    end
    local ok, err = map:move_obj(player_id, x, y)
    if not ok then
        return false, err or "move failed"
    end
    st.x = x
    st.y = y
    view.sync_diff_on_move(player_id, map, st)
    return true, helpers.with_shard(map, {
        map_id = map.map_id,
        x = x,
        y = y,
    })
end

-- 跨片移动：先离旧片，再通知目标片 accept，失败则回滚
function M.transfer_observer(player_id, dest_shard, x, y)
    local st = ctx.player_state[player_id]
    local map = helpers.current_map(st)
    if not map then
        return false, "player not in map"
    end
    local dest = shard.addr(map.map_id, dest_shard)
    if not dest then
        return false, "目标战区不可用"
    end
    local old_x, old_y = st.x, st.y
    local snap = {
        player_id = player_id,
        player_name = st.player_name,
        x = x,
        y = y,
        move_test_deadline = st.move_test_deadline, -- 压测接力字段，无则为 nil
    }
    if st.current_scene_id and st.current_scene_id > 0 then
        pcall(function()
            map:leave_obj(player_id)
        end)
    end
    view.clear_view_state(st)
    st.current_map_id = 0
    st.current_scene_id = 0
    local ok, result = skynet.call(dest, "lua", "accept_observer", snap)
    if not ok then
        snap.x = old_x
        snap.y = old_y
        local restored, restore_err = M.accept_observer(snap)
        if not restored then
            log.error("observer transfer rollback failed, player_id=%s err=%s",
                tostring(player_id), tostring(restore_err))
        end
        return false, result or "跨区失败"
    end
    return true, result
end

-- 目标片接收观察者：重建 observer 进 AOI，返回全量视野
function M.accept_observer(snap)
    local map = ctx.map
    if not map then
        return false, "map not found"
    end
    local player_id = snap and snap.player_id
    if not player_id then
        return false, "invalid observer"
    end
    if not map:owns_pos(snap.x, snap.y) then
        return false, "pos not in this shard"
    end
    local st = helpers.get_or_init_player_state(player_id)
    if st.current_scene_id and st.current_scene_id > 0 then
        pcall(function()
            map:leave_obj(player_id)
        end)
    end
    st.player_id = player_id
    st.player_name = snap.player_name or st.player_name or ("Player_" .. tostring(player_id))
    st.move_test_deadline = snap.move_test_deadline -- 压测接力字段
    local observer = aoi_object.Observer.new({
        uid = player_id,
        player_id = player_id,
        player_name = st.player_name,
        x = snap.x,
        y = snap.y,
        view_range = ctx.MAP_VIEW_RANGE,
        map_id = map.map_id,
        shard_id = map.shard_id,
        owner_shard_id = map.shard_id,
        is_ghost = false,
    })
    local enter_ok, enter_err = map:enter_obj(observer)
    if not enter_ok then
        return false, enter_err or "enter aoi failed"
    end
    st.current_map_id = map.map_id
    st.current_scene_id = map.map_id
    st.x = snap.x
    st.y = snap.y
    local monsters, items, marches, buildings = view.collect_visible(map, st)
    view.sync_view(player_id, map, st)
    return true, helpers.with_shard(map, {
        map_id = map.map_id,
        scene_id = map.map_id,
        x = st.x,
        y = st.y,
        monsters = monsters,
        items = items,
        marches = marches,
        buildings = buildings,
    })
end

-- 离图：清行军、离 AOI、清视野状态、释放战斗锁
function M.leave_map(player_id)
    march_runtime.despawn_player_marches(player_id)
    local st = ctx.player_state[player_id]
    if not st then
        return true
    end
    local map_id = st.current_map_id or 0
    local map = helpers.get_map(map_id)
    if st.current_scene_id and st.current_scene_id > 0 and map then
        pcall(function()
            map:leave_obj(player_id)
        end)
    end
    view.clear_view_state(st)
    st.current_map_id = 0
    st.current_scene_id = 0
    local battle = ctx.player_battles[player_id]
    if battle then
        if battle.remote then
            interact.cancel_owner_battle(map, player_id, battle.owner_shard_id, battle.monster_uid)
        elseif battle.lock_key then
            interact.release_lock(battle.lock_key)
        end
    end
    ctx.player_battles[player_id] = nil
    local remote = ctx.remote_battles[player_id]
    if remote and remote.lock_key then
        interact.release_lock(remote.lock_key)
    end
    ctx.remote_battles[player_id] = nil
    map_store.flush()
    return true
end

function M.sync_player_view(player_id)
    interact.cleanup_expired_locks()
    interact.cleanup_stale_battles()
    local st = helpers.get_or_init_player_state(player_id)
    local map = helpers.current_map(st)
    if not map then
        return false, "player not in map"
    end
    view.sync_view(player_id, map, st)
    return true, M.get_state(player_id)
end

function M.get_state(player_id)
    local st = helpers.get_or_init_player_state(player_id)
    local map = helpers.current_map(st)
    local monsters, items, marches, buildings = {}, {}, {}, {}
    if map then
        monsters, items, marches, buildings = view.collect_visible(map, st)
    end
    return helpers.with_shard(map, {
        map_id = st.current_map_id or 0,
        scene_id = st.current_scene_id or 0,
        x = st.x or 0,
        y = st.y or 0,
        monsters = monsters,
        items = items,
        marches = marches,
        buildings = buildings,
    })
end

function M.ghost_upsert(payload)
    local map = ctx.map
    if not map or not payload then
        return
    end
    map:apply_ghost_upsert(payload)
end

function M.ghost_remove(uid, _x, _y)
    local map = ctx.map
    if not map then
        return
    end
    map:apply_ghost_remove(uid)
end

function M.resync_border_ghosts()
    local map = ctx.map
    if not map then
        return
    end
    map:resync_border_ghosts()
end

return M
