-- 大地图观察者：进图 / 镜头移动 / 跨片 / 离图 / 状态
-- 玩法锚点 = 玩家主城（AOI 里的 BUILDING 实体，持久化、归主城所在片）；
-- player_state 只存视野状态，跟着镜头走。
local skynet = require "skynet"
local log = require "log"
local map_store = require "map.map_store"
local chunk = require "map.chunk"
local shard = require "map.shard"
local aoi_object = require "map.aoi_object"
local service_ctx = require "runtime.service_ctx"
local view = require "map.view_sync"
local helpers = require "map.helpers"
local interact = require "map.interact"
local march_runtime = require "map.march_runtime"

local ctx = service_ctx.get("map.shard_service", {})
local M = {}

ctx.player_state = ctx.player_state or {}
ctx.MAP_VIEW_RANGE = 100

local CITY_BUILDING_ID = 1 -- 主城的 building_id 配置占位

-- 主城落成：出生点建城（BUILDING 实体，owner=玩家，持久化；uid 约定 city_<player_id>）
local function create_city(map, player_id)
    local start = map.def.start or {}
    local x, y
    if start.x and start.y and map:owns_pos(start.x, start.y) then
        x, y = start.x, start.y
    else
        x, y = map:rand_spawn()
    end
    local city = {
        uid = "city_" .. tostring(player_id),
        type = aoi_object.TYPE.BUILDING,
        map_id = map.map_id,
        shard_id = map.shard_id,
        owner_shard_id = map.shard_id,
        x = x,
        y = y,
        view_range = 0,
        is_ghost = false,
        alive = true,
        owner_player_id = player_id,
        building_id = CITY_BUILDING_ID,
        level = 1,
        kind = "city",
        chunk_id = chunk.from_pos(x, y, map.def.chunk_size),
        version = 1,
    }
    city._id = map_store.make_id(map.map_id, aoi_object.TYPE.BUILDING, city.uid)
    map:attach(city, aoi_object.TYPE.BUILDING)
    if not city.in_aoi then
        return nil
    end
    map:save(city)
    log.info("city created, player_id=%s pos=(%d,%d) shard_id=%s",
        tostring(player_id), x, y, tostring(map.shard_id))
    return city
end

-- 全图寻城：逐片问 find_city。任一片不可用则失败（宁可进不了图，不冒重复建城的险）
-- 返回 city_shard, info, err
local function find_city_shard(map, player_id)
    for _, sid in ipairs(shard.all_ids()) do
        if sid ~= map.shard_id then
            local addr = shard.addr(map.map_id, sid)
            if not addr then
                return nil, nil, "地图服务未就绪"
            end
            local ok, info = skynet.call(addr, "lua", "find_city", player_id)
            if ok and type(info) == "table" then
                return sid, info
            end
        end
    end
    return nil
end

function M.enter_map(player_id, player_name, map_id)
    local map = helpers.get_map(map_id)
    if not map then
        return false, "map not found"
    end

    -- 主城定位：本片有→直接用；别片有→转去该片进图；全图没有→本片建城
    local city = map:get_city(player_id)
    if not city then
        local city_shard, _, find_err = find_city_shard(map, player_id)
        if find_err then
            return false, find_err
        end
        if city_shard then
            local addr = shard.addr(map_id, city_shard)
            return skynet.call(addr, "lua", "enter_map", player_id, player_name, map_id)
        end
        city = create_city(map, player_id)
        if not city then
            return false, "主城创建失败"
        end
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
    -- 镜头落点 = 主城坐标
    local x, y = city.x, city.y
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

-- 移动 = 镜头移动：只动 AOI 观察者（视野）。玩法锚点是主城实体，不在这里
function M.move(player_id, x, y)
    local st = helpers.get_or_init_player_state(player_id)
    local map = helpers.current_map(st)
    if not map or not st.current_scene_id or st.current_scene_id <= 0 then
        return false, "player not in map"
    end
    -- 越界贴边，避免 AOI 网格默默 clamp 出莫名位置
    x = math.max(1, math.min(tonumber(x) or 1, map.def.width))
    y = math.max(1, math.min(tonumber(y) or 1, map.def.height))
    local dest_shard = shard.shard_id_of_pos(x, y, map.def)
    if dest_shard ~= map.shard_id then
        return M.transfer_observer(player_id, dest_shard, x, y)
    end
    local ok, err = map:move_obj(player_id, x, y)
    if not ok then
        return false, err or "move failed"
    end
    view.sync_diff_on_move(player_id, map, st)
    return true, helpers.with_shard(map, {
        map_id = map.map_id,
        x = x,
        y = y,
    })
end

-- 跨片迁移：观察者（镜头）落到目标片 (x,y)，player_state（纯视野状态）随镜头走。
-- 玩法锚点 = 主城实体，归主城所在片，不随迁移。先离旧片再 accept，失败回滚。
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
    -- 回滚落点 = 观察者迁移前的真实位置
    local old_obj = map:get_obj(player_id)
    local old_x = old_obj and old_obj.x or x
    local old_y = old_obj and old_obj.y or y
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
        snap.x, snap.y = old_x, old_y
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
    local monsters, items, marches, buildings = view.collect_visible(map, st)
    view.sync_view(player_id, map, st)
    return true, helpers.with_shard(map, {
        map_id = map.map_id,
        scene_id = map.map_id,
        x = snap.x, -- 观察者（镜头）落点
        y = snap.y,
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
    local x, y = 0, 0
    if map then
        -- 返回镜头位置（观察者实体坐标）；客户端要找主城看 buildings 里 owner 是自己的
        local obj = map:get_obj(player_id)
        if obj then
            x, y = obj.x, obj.y
        end
        monsters, items, marches, buildings = view.collect_visible(map, st)
    end
    return helpers.with_shard(map, {
        map_id = st.current_map_id or 0,
        scene_id = st.current_scene_id or 0,
        x = x,
        y = y,
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
