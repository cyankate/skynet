-- 大地图分片服务入口：CMD 只做对外入口，转发到各业务模块
local skynet = require "skynet"
local log = require "log"
local service_ctx = require "runtime.service_ctx"
local map_store = require "map.map_store"
local Map = require "map.map"

local ctx = service_ctx.get("map.map_service", {})


ctx.WORLD_SAVE_INTERVAL = 10 * 100
ctx.MARCH_TICK = 10

local observer = require "map.observer"
local interact = require "map.interact"
local march_runtime = require "map.march_runtime"

-- observer
function CMD.enter_map(player_id, player_name, map_id)
    return observer.enter_map(player_id, player_name, map_id)
end

function CMD.move(player_id, x, y)
    return observer.move(player_id, x, y)
end

function CMD.transfer_observer(player_id, dest_shard, x, y)
    return observer.transfer_observer(player_id, dest_shard, x, y)
end

function CMD.accept_observer(snap)
    return observer.accept_observer(snap)
end

function CMD.leave_map(player_id)
    return observer.leave_map(player_id)
end

function CMD.sync_player_view(player_id)
    return observer.sync_player_view(player_id)
end

function CMD.get_state(player_id)
    return observer.get_state(player_id)
end

function CMD.ghost_upsert(payload)
    return observer.ghost_upsert(payload)
end

function CMD.ghost_remove(uid, x, y)
    return observer.ghost_remove(uid, x, y)
end

function CMD.resync_border_ghosts()
    return observer.resync_border_ghosts()
end

-- interact
function CMD.interact_monster(player_id, monster_uid)
    return interact.interact_monster(player_id, monster_uid)
end

function CMD.on_battle_result(player_id, monster_uid, win)
    return interact.on_battle_result(player_id, monster_uid, win)
end

function CMD.pick_item(player_id, item_uid)
    return interact.pick_item(player_id, item_uid)
end

function CMD.try_pick_public(uid, req)
    return interact.try_pick_public(uid, req)
end

function CMD.try_interact_public(uid, req)
    return interact.try_interact_public(uid, req)
end

function CMD.apply_battle_result(player_id, monster_uid, win)
    return interact.apply_battle_result(player_id, monster_uid, win)
end

function CMD.cancel_remote_battle(player_id, monster_uid)
    return interact.cancel_remote_battle(player_id, monster_uid)
end

-- march_runtime
function CMD.query_march_count(player_id)
    return march_runtime.query_march_count(player_id)
end

function CMD.tick_marches()
    return march_runtime.tick_marches()
end

function CMD.march_start(player_id, x, y)
    return march_runtime.march_start(player_id, x, y)
end

function CMD.march_attack(player_id, march_uid, target_uid)
    return march_runtime.march_attack(player_id, march_uid, target_uid)
end

function CMD.march_cancel(player_id, march_uid)
    return march_runtime.march_cancel(player_id, march_uid)
end

function CMD.query_march(uid)
    return march_runtime.query_march(uid)
end

function CMD.apply_march_damage(uid, dmg, battle_id)
    return march_runtime.apply_march_damage(uid, dmg, battle_id)
end

function CMD.march_set_defender(uid, info)
    return march_runtime.march_set_defender(uid, info)
end

function CMD.march_clear_battle(uid, battle_id, reason)
    return march_runtime.march_clear_battle(uid, battle_id, reason)
end

function CMD.march_update_host(uid, battle_id, host_shard)
    return march_runtime.march_update_host(uid, battle_id, host_shard)
end

function CMD.battle_defender_moved(battle_id, dest_shard, uid)
    return march_runtime.battle_defender_moved(battle_id, dest_shard, uid)
end

function CMD.end_hosted_battle(battle_id, reason)
    return march_runtime.end_hosted_battle(battle_id, reason)
end

function CMD.accept_march_handoff(snap)
    return march_runtime.accept_march_handoff(snap)
end

-- P1: 压测入口（debug console 调：call .map.1.0 "stress_test" 100 1000）
function CMD.stress_test(observer_count, obj_count)
    local view_sync = require "map.view_sync"
    return view_sync._stress_test(ctx.map, tonumber(observer_count), tonumber(obj_count))
end

local function start_world_save_timer()
    local function tick()
        skynet.timeout(ctx.WORLD_SAVE_INTERVAL, tick)
        map_store.flush()
    end
    skynet.timeout(ctx.WORLD_SAVE_INTERVAL, tick)
end

local function start_march_timer()
    local function tick()
        skynet.timeout(ctx.MARCH_TICK, tick)
        local ok, err = pcall(function()
            march_runtime.tick_marches()
        end)
        if not ok then
            log.error("march tick failed: %s", tostring(err))
        end
    end
    skynet.timeout(ctx.MARCH_TICK, tick)
end

function CMD.init()
    if ctx._inited then
        return true
    end
    ctx._inited = true
    local bind = package.loaded["map.worker_bind"]
    local map_id = bind and tonumber(bind.map_id)
    local shard_id = bind and tonumber(bind.shard_id)
    if not map_id or shard_id == nil then
        return false, "map worker missing map_id/shard_id"
    end
    local def = Map.default_defs()[map_id]
    if not def then
        return false, "map def not found"
    end
    ctx.map = Map.new(def, shard_id)
    ctx.map:bootstrap()
    start_world_save_timer()
    start_march_timer()
    log.info("Map service initialized, map_id=%s shard_id=%s", tostring(map_id), tostring(shard_id))
    return true
end

return CMD
