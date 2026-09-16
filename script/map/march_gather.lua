-- 行军采集：占点、计划定时器、回城交货。
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
package.loaded["map.march_gather"] = M
local runtime = require "map.march_runtime"

local function sync_resource(map, res)
    if not map or not res then
        return
    end
    map_store.mark_dirty(res)
    if res.in_aoi then
        map:sync_ghosts(res)
        view.sync_obj_attr_around(map, res)
    end
end

local function local_resource(map, uid)
    if not map then
        return nil
    end
    uid = tostring(uid or "")
    return map.public_resources and map.public_resources[uid]
end

function M.release_occupy(map, m)
    if not map or not m then
        return
    end
    local res = local_resource(map, m.target_uid)
    if res and res.occupier_uid == m.uid then
        res.occupier_uid = ""
        aoi_object.mark_dirty(res, "occupier_uid")
        sync_resource(map, res)
    end
end

local function occupy_resource(map, m, res)
    if not res or not m then
        return false, "resource not found"
    end
    if res.gatherable == false then
        return false, "not gatherable"
    end
    if res.alive == false then
        return false, "resource gone"
    end
    if (tonumber(res.count) or 0) <= 0 then
        return false, "depleted"
    end
    local occ = res.occupier_uid or ""
    if occ ~= "" and occ ~= m.uid then
        return false, "occupied"
    end
    res.occupier_uid = m.uid
    aoi_object.mark_dirty(res, "occupier_uid")
    sync_resource(map, res)
    return true
end

local function clear_gather_plan(m)
    if not m then
        return
    end
    m.gather_seq = (m.gather_seq or 0) + 1
    m.gather_speed = 0
    m.gather_amount = 0
    m.gather_duration = 0
    m.gather_start = 0
    m.gather_end = 0
    aoi_object.mark_dirty(m, "gather_speed")
    aoi_object.mark_dirty(m, "gather_amount")
    aoi_object.mark_dirty(m, "gather_duration")
end

local function gather_elapsed_take(m)
    local planned = tonumber(m.gather_amount) or 0
    if planned <= 0 then
        return 0
    end
    local speed = tonumber(m.gather_speed) or march.GATHER_SPEED
    if speed <= 0 then
        return planned
    end
    local start = tonumber(m.gather_start) or skynet.now()
    local elapsed_sec = (skynet.now() - start) / 100
    local take = math.floor(speed * elapsed_sec + 1e-6)
    if take < 0 then
        take = 0
    elseif take > planned then
        take = planned
    end
    return take
end

local function settle_gather(map, m, take)
    take = math.floor(tonumber(take) or 0)
    if take < 0 then
        take = 0
    end
    local res = local_resource(map, m.target_uid)
    if res and take > 0 then
        local remaining = tonumber(res.count) or 0
        if take > remaining then
            take = remaining
        end
        res.count = remaining - take
        aoi_object.mark_dirty(res, "count")
        sync_resource(map, res)
    elseif take > 0 then
        take = 0
    end
    if take > 0 then
        m.cargo_count = (tonumber(m.cargo_count) or 0) + take
        aoi_object.mark_dirty(m, "cargo_count")
    end
    clear_gather_plan(m)
    if map and m.in_aoi then
        map:sync_ghosts(m)
        view.sync_obj_attr_around(map, m)
    end
end

function M.settle_gather_progress(map, m)
    if not m then
        return
    end
    if (tonumber(m.gather_amount) or 0) <= 0 then
        m.gather_seq = (m.gather_seq or 0) + 1
        return
    end
    settle_gather(map, m, gather_elapsed_take(m))
end

function M.schedule_gather_done(map, m)
    if not m then
        return
    end
    local seq = m.gather_seq or 0
    local uid = m.uid
    local remain_tick = (tonumber(m.gather_end) or skynet.now()) - skynet.now()
    if remain_tick < 1 then
        remain_tick = 1
    end
    skynet.timeout(remain_tick, function()
        if m.gather_seq ~= seq then
            return
        end
        local cur = ctx.marches[uid]
        if not cur or cur ~= m or cur.state ~= march.STATE_GATHERING then
            return
        end
        local cur_map = ctx.map or map
        settle_gather(cur_map, cur, tonumber(cur.gather_amount) or 0)
        M.begin_return(cur_map, cur)
    end)
end

function M.begin_return(map, m)
    if not m then
        return
    end
    M.settle_gather_progress(map, m)
    M.release_occupy(map, m)
    m.intent = march.INTENT_RETURN
    m.state = march.STATE_MARCHING
    aoi_object.mark_dirty(m, "intent")
    aoi_object.mark_dirty(m, "state")
    local city = runtime.find_owner_city(map, m.owner_player_id)
    if not city then
        log.error("gather return: city missing, despawn uid=%s", tostring(m.uid))
        runtime.despawn_march(map, m, "no_city")
        return
    end
    m.target_uid = city.uid or ("city_" .. tostring(m.owner_player_id))
    aoi_object.mark_dirty(m, "target_uid")
    local path = runtime.find_map_path(map, m.x, m.y, city.x, city.y)
    if not path then
        path = { { x = m.x, y = m.y }, { x = city.x, y = city.y } }
    end
    runtime.apply_march_path(m, path, city.x, city.y)
    runtime.notify_march_sync(map, m)
    runtime.broadcast_plan(map, m)
end

function M.begin_gather(map, m)
    if not m or m.state == march.STATE_GATHERING then
        return
    end
    local res = local_resource(map, m.target_uid)
    if not res then
        if map:owns_pos(m.x, m.y) then
            M.begin_return(map, m)
        end
        return
    end
    if not march.in_range(m.x, m.y, res.x, res.y, march.GATHER_RANGE) then
        local path = runtime.find_map_path(map, m.x, m.y, res.x, res.y, true)
        if not path then
            path = { { x = m.x, y = m.y }, { x = res.x, y = res.y } }
        end
        runtime.apply_march_path(m, path, res.x, res.y)
        runtime.broadcast_plan(map, m)
        return
    end
    local ok, err = occupy_resource(map, m, res)
    if not ok then
        log.info("gather occupy failed uid=%s res=%s err=%s", tostring(m.uid), tostring(m.target_uid), tostring(err))
        M.begin_return(map, m)
        return
    end
    local remaining = tonumber(res.count) or 0
    local cargo = tonumber(m.cargo_count) or 0
    local cap = tonumber(m.load_max) or march.LOAD_MAX
    local take = remaining
    local room = cap - cargo
    if take > room then
        take = room
    end
    if take <= 0 then
        M.begin_return(map, m)
        return
    end
    local speed = march.GATHER_SPEED
    local duration = take / speed
    m.intent = march.INTENT_GATHER
    m.state = march.STATE_GATHERING
    m.cargo_item_id = tonumber(res.item_id) or m.cargo_item_id or 0
    m.waypoints = { { x = m.x, y = m.y } }
    m.wp_index = 2
    m.gather_speed = speed
    m.gather_amount = take
    m.gather_duration = duration
    m.gather_seq = (m.gather_seq or 0) + 1
    m.gather_start = skynet.now()
    m.gather_end = m.gather_start + math.max(1, math.floor(duration * 100 + 0.5))
    aoi_object.mark_dirty(m, "intent")
    aoi_object.mark_dirty(m, "state")
    aoi_object.mark_dirty(m, "cargo_item_id")
    aoi_object.mark_dirty(m, "gather_speed")
    aoi_object.mark_dirty(m, "gather_amount")
    aoi_object.mark_dirty(m, "gather_duration")
    aoi_object.mark_dirty(m, "x")
    aoi_object.mark_dirty(m, "y")
    aoi_object.mark_dirty(m, "waypoints")
    aoi_object.mark_dirty(m, "wp_index")
    runtime.notify_march_sync(map, m)
    if m.in_aoi then
        map:sync_ghosts(m)
        view.sync_obj_attr_around(map, m)
    end
    M.schedule_gather_done(map, m)
end

local function deposit_cargo(m)
    local count = tonumber(m.cargo_count) or 0
    local item_id = tonumber(m.cargo_item_id) or 0
    if count <= 0 or item_id <= 0 or not m.owner_player_id then
        return true
    end
    local ok, err = protocol_handler.call_agent(m.owner_player_id, "add_items", {
        player_id = m.owner_player_id,
        items = { [item_id] = count },
        reason = "map_gather",
    })
    if not ok then
        log.error("gather deposit failed uid=%s player=%s err=%s",
            tostring(m.uid), tostring(m.owner_player_id), tostring(err))
        return false, err
    end
    m.cargo_count = 0
    aoi_object.mark_dirty(m, "cargo_count")
    return true
end

function M.finish_return(map, m)
    local city = map:get_city(m.owner_player_id)
    if not city then
        return
    end
    if not march.in_range(m.x, m.y, city.x, city.y, march.CITY_ARRIVE_RANGE) then
        local path = runtime.find_map_path(map, m.x, m.y, city.x, city.y)
        if not path then
            path = { { x = m.x, y = m.y }, { x = city.x, y = city.y } }
        end
        runtime.apply_march_path(m, path, city.x, city.y)
        runtime.broadcast_plan(map, m)
        return
    end
    deposit_cargo(m)
    runtime.despawn_march(map, m, "returned")
end

function M.query_resource(uid)
    local map = ctx.map
    uid = tostring(uid or "")
    local res = local_resource(map, uid)
    if not res then
        return false, "resource not found"
    end
    return true, {
        uid = res.uid,
        x = res.x,
        y = res.y,
        count = tonumber(res.count) or 0,
        occupier_uid = res.occupier_uid or "",
        item_id = tonumber(res.item_id) or 0,
        shard_id = map.shard_id,
        alive = res.alive ~= false,
        gatherable = res.gatherable ~= false,
    }
end

local function resolve_resource(map, uid)
    uid = tostring(uid or "")
    if uid == "" or not map then
        return nil
    end
    local ok, snap = M.query_resource(uid)
    if ok and type(snap) == "table" then
        return snap
    end
    for _, sid in ipairs(shard.all_ids()) do
        if sid ~= map.shard_id then
            local addr = shard.addr(map.map_id, sid)
            if addr then
                local rok, result = skynet.call(addr, "lua", "query_resource", uid)
                if rok and type(result) == "table" then
                    return result
                end
            end
        end
    end
    return nil
end

function M.march_gather(player_id, resource_uid)
    local map = ctx.map
    if not map then
        return false, "map not found"
    end
    local city = map:get_city(player_id)
    if not city then
        return false, "主城不在本战区"
    end
    resource_uid = tostring(resource_uid or "")
    if resource_uid == "" then
        return false, "resource_uid is required"
    end
    local snap = resolve_resource(map, resource_uid)
    if not snap then
        return false, "resource not found"
    end
    if snap.gatherable == false then
        return false, "not gatherable"
    end
    if not snap.alive or (tonumber(snap.count) or 0) <= 0 then
        return false, "depleted"
    end
    local occ = snap.occupier_uid or ""
    if occ ~= "" then
        return false, "occupied"
    end
    if runtime.count_all_player_marches(player_id) >= march.MAX_PER_PLAYER then
        return false, "行军数量已满"
    end
    local tx, ty = march.clamp(map.def, snap.x, snap.y)
    local path, path_err = runtime.find_map_path(map, city.x, city.y, tx, ty)
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
        intent = march.INTENT_GATHER,
        target_uid = resource_uid,
        cargo_item_id = snap.item_id or 0,
        load_max = march.LOAD_MAX,
    })
    aoi_object.mark_dirty(m, "intent")
    aoi_object.mark_dirty(m, "target_uid")
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
        march_uid = uid,
        resource_uid = resource_uid,
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

return M
