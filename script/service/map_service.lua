local skynet = require "skynet"
local log = require "log"
local service_ctx = require "runtime.service_ctx"
local protocol_handler = require "protocol_handler"
local map_store = require "map.map_store"
local shard = require "map.shard"
local Map = require "map.map"
local march = require "map.march"
local aoi_object = require "map.aoi_object"

local M = service_ctx.get("map.map_service", {})
M._inited = M._inited or false
M.map = M.map or nil
M.player_state = M.player_state or {}
M.player_private_monsters = M.player_private_monsters or {}
M.player_private_items = M.player_private_items or {}
M.player_battles = M.player_battles or {}
M.remote_battles = M.remote_battles or {}
M.flow_notify_cache = M.flow_notify_cache or {}
M.obj_locks = M.obj_locks or {}
M.marches = M.marches or {}
M.player_marches = M.player_marches or {}
M.field_battles = M.field_battles or {}
M.march_seq = M.march_seq or {}

local BATTLE_TIMEOUT_TICK = 1800 -- 180s, skynet.now() tick=10ms
local WORLD_SAVE_INTERVAL = 10 * 100 -- 10s
local MAP_VIEW_RANGE = 100
local MAP_ATTACK_RANGE = 100
local MARCH_TICK = 10 -- 0.1s
local CHASE_REPATH_DIST = 32
local PATHFINDING_NAME = ".pathfinding"

local function copy_table(t)
    if type(t) ~= "table" then
        return t
    end
    local n = {}
    for k, v in pairs(t) do
        if type(v) == "table" then
            n[k] = copy_table(v)
        else
            n[k] = v
        end
    end
    return n
end

local function relocate_into_shard(world, obj)
    if not obj or world:owns_pos(obj.x, obj.y) then
        return
    end
    obj.x, obj.y = world:rand_spawn()
    obj.region_id = world:region_id(obj.x, obj.y)
    obj.in_aoi = false
end

local function relocate_objs(world, objs)
    for _, obj in pairs(objs or {}) do
        relocate_into_shard(world, obj)
    end
end

local function with_shard(world, payload)
    payload = payload or {}
    payload.map_id = payload.map_id or (world and world.map_id or 0)
    payload.shard_id = world and world.shard_id or 0
    return payload
end

local function get_map(map_id)
    local world = M.map
    if not world then
        return nil
    end
    if map_id and tonumber(map_id) ~= 0 and tonumber(map_id) ~= world.map_id then
        return nil
    end
    return world
end

local function get_or_init_player_state(player_id)
    local st = M.player_state[player_id]
    if st then
        return st
    end
    st = {
        current_map_id = 0,
        current_scene_id = 0,
        current_region_id = 0,
        x = 0,
        y = 0,
        key_count = 0,
        region_progress = {},
    }
    M.player_state[player_id] = st
    return st
end

local function current_map(st)
    if not st or not st.current_map_id or st.current_map_id <= 0 then
        return nil
    end
    return get_map(st.current_map_id)
end

local function get_players_visible_region(map_id, region_id)
    local players = {}
    for player_id, st in pairs(M.player_state) do
        if st.current_map_id == map_id and st.current_scene_id > 0 then
            if st.current_region_id == region_id then
                players[#players + 1] = player_id
            else
                local p = st.region_progress and st.region_progress[region_id]
                if p and p.cleared then
                    players[#players + 1] = player_id
                end
            end
        end
    end
    return players
end

local function attach_private_objs(world, player_id)
    local monsters = (M.player_private_monsters[player_id] or {})[world.map_id]
    local items = (M.player_private_items[player_id] or {})[world.map_id]
    relocate_objs(world, monsters)
    relocate_objs(world, items)
    world:attach_all(monsters, aoi_object.TYPE.MONSTER)
    world:attach_all(items, aoi_object.TYPE.RESOURCE)
end

local function detach_private_objs(world, player_id)
    world:detach_all((M.player_private_monsters[player_id] or {})[world.map_id])
    world:detach_all((M.player_private_items[player_id] or {})[world.map_id])
end

local function ensure_player_private_monsters(player_id, world)
    local by_player = M.player_private_monsters[player_id]
    if not by_player then
        by_player = {}
        M.player_private_monsters[player_id] = by_player
    end
    local monsters = by_player[world.map_id]
    if monsters then
        return monsters
    end
    monsters = {}
    for i = 1, 8 do
        local x, y = world:rand_spawn()
        local uid = string.format("pri_%d_%d_%d", player_id, world.map_id, i)
        monsters[uid] = {
            uid = uid,
            type = aoi_object.TYPE.MONSTER,
            map_id = world.map_id,
            x = x,
            y = y,
            region_id = world:region_id(x, y),
            alive = true,
            kind = "private",
            visibility_layer = 1,
            owner_player_id = player_id,
            in_aoi = false,
        }
    end
    by_player[world.map_id] = monsters
    return monsters
end

local function ensure_player_private_items(player_id, world)
    local by_player = M.player_private_items[player_id]
    if not by_player then
        by_player = {}
        M.player_private_items[player_id] = by_player
    end
    local items = by_player[world.map_id]
    if items then
        return items
    end
    items = {}
    for i = 1, 12 do
        local x, y = world:rand_spawn()
        local uid = string.format("pri_i_%d_%d_%d", player_id, world.map_id, i)
        items[uid] = {
            uid = uid,
            type = aoi_object.TYPE.RESOURCE,
            map_id = world.map_id,
            x = x,
            y = y,
            region_id = world:region_id(x, y),
            alive = true,
            item_id = 10001 + ((i - 1) % 3),
            count = 1,
            visibility_layer = 1,
            owner_player_id = player_id,
            in_aoi = false,
        }
    end
    by_player[world.map_id] = items
    return items
end

local function acquire_lock(lock_key)
    local now = skynet.now()
    local expire_at = M.obj_locks[lock_key]
    if expire_at and expire_at > now then
        return false
    end
    M.obj_locks[lock_key] = now + 200
    return true
end

local function release_lock(lock_key)
    M.obj_locks[lock_key] = nil
end

local function cleanup_expired_locks()
    local now = skynet.now()
    for lock_key, expire_at in pairs(M.obj_locks) do
        if (tonumber(expire_at) or 0) <= now then
            M.obj_locks[lock_key] = nil
        end
    end
end

local function cleanup_stale_battles()
    local now = skynet.now()
    local world = M.map
    for player_id, battle in pairs(M.player_battles) do
        local deadline = tonumber(battle and battle.deadline_tick) or 0
        if deadline > 0 and deadline <= now then
            if battle.owner_shard_id ~= nil and world and battle.owner_shard_id ~= world.shard_id then
                local addr = shard.addr(world.map_id, battle.owner_shard_id)
                if addr then
                    skynet.send(addr, "lua", "cancel_remote_battle", player_id, battle.monster_uid)
                end
            elseif battle.lock_key then
                release_lock(battle.lock_key)
            end
            M.player_battles[player_id] = nil
            log.warning("map battle timeout cleanup, player_id=%s, monster_uid=%s", tostring(player_id), tostring(battle.monster_uid))
        end
    end
    for player_id, battle in pairs(M.remote_battles) do
        local deadline = tonumber(battle and battle.deadline_tick) or 0
        if deadline > 0 and deadline <= now then
            if battle.lock_key then
                release_lock(battle.lock_key)
            end
            M.remote_battles[player_id] = nil
            log.warning("map remote battle timeout cleanup, player_id=%s, monster_uid=%s", tostring(player_id), tostring(battle.monster_uid))
        end
    end
end

local function in_attack_range(x1, y1, x2, y2, range)
    range = tonumber(range) or MAP_ATTACK_RANGE
    local dx = (tonumber(x1) or 0) - (tonumber(x2) or 0)
    local dy = (tonumber(y1) or 0) - (tonumber(y2) or 0)
    return (dx * dx + dy * dy) <= (range * range)
end

local function hold_lock(lock_key)
    if not lock_key then
        return
    end
    M.obj_locks[lock_key] = skynet.now() + BATTLE_TIMEOUT_TICK
end

local function cancel_owner_battle(world, player_id, owner_shard_id, monster_uid)
    if not world or owner_shard_id == nil or owner_shard_id == world.shard_id then
        return
    end
    local addr = shard.addr(world.map_id, owner_shard_id)
    if addr then
        skynet.send(addr, "lua", "cancel_remote_battle", player_id, monster_uid)
    end
end

local function start_monster_instance(world, player_id, uid)
    local instanceS = skynet.localname(".instance")
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
            map_id = world.map_id,
            shard_id = world.shard_id,
            monster_uid = uid,
        },
    })
end

local function notify_monster_removed(map_id, region_id, monster_uid, x, y, killer_player_id)
    local player_ids
    if string.sub(monster_uid or "", 1, 4) == "pri_" then
        player_ids = { killer_player_id }
    else
        player_ids = get_players_visible_region(map_id, region_id)
    end
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

local function notify_item_removed(map_id, region_id, item_uid, x, y, picker_player_id)
    local player_ids
    if string.sub(item_uid or "", 1, 6) == "pri_i_" then
        player_ids = { picker_player_id }
    else
        player_ids = get_players_visible_region(map_id, region_id)
    end
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

local function notify_region_cleared(map_id, region_id, trigger_player_id, scope)
    local player_ids
    if scope == "private" then
        player_ids = { trigger_player_id }
    else
        player_ids = get_players_visible_region(map_id, region_id)
    end
    if #player_ids == 0 then
        return
    end
    protocol_handler.send_to_players(player_ids, "map_region_cleared_notify", {
        map_id = map_id,
        region_id = region_id,
        trigger_player_id = trigger_player_id or 0,
        scope = scope or "public",
    })
end

local function notify_flow(player_id, map_id, phase, region_id, extra)
    local now = skynet.now()
    local cache = M.flow_notify_cache[player_id] or {}
    M.flow_notify_cache[player_id] = cache

    local payload = {
        map_id = map_id or 0,
        phase = phase or "",
        region_id = region_id or 0,
        explored_region_count = 0,
        total_region_count = 0,
        fog_percent = 0,
        key_count = 0,
        ts = os.time(),
    }
    if type(extra) == "table" then
        for k, v in pairs(extra) do
            payload[k] = v
        end
    end

    local key = string.format("%s:%d", payload.phase, payload.region_id or 0)
    local last = cache[key]
    if last then
        local same_content =
            last.map_id == payload.map_id and
            last.explored_region_count == payload.explored_region_count and
            last.total_region_count == payload.total_region_count and
            last.fog_percent == payload.fog_percent and
            last.key_count == payload.key_count
        if same_content then
            return
        end
        if (now - (last._tick or 0)) < 30 then
            return
        end
    end

    payload._tick = now
    cache[key] = payload
    protocol_handler.send_to_player(player_id, "map_flow_notify", payload)
end

local function notify_region_unlocked(player_id, map_id, region_id, key_count)
    protocol_handler.send_to_player(player_id, "map_region_unlocked_notify", {
        map_id = map_id or 0,
        region_id = region_id or 0,
        key_count = key_count or 0,
    })
end

local function summarize_progress(st, world)
    local total = math.max(1, tonumber(world and world.def.region_count) or 1)
    local explored = 0
    for _, p in pairs(st.region_progress or {}) do
        if p.explored then
            explored = explored + 1
        end
    end
    local fog_percent = math.max(0, math.min(100, math.floor((1 - explored / total) * 100)))
    return explored, total, fog_percent
end

local function is_region_visible(st, region_id)
    if region_id == st.current_region_id then
        return true
    end
    local p = st.region_progress[region_id]
    return p and p.cleared or false
end

local function can_interact_obj(st, world, obj)
    if not st or not obj then
        return false, "invalid state or obj"
    end
    local owner_id = obj.owner_player_id or 0
    if owner_id ~= 0 and owner_id ~= st.player_id then
        return false, "obj not owned by player"
    end
    local region_id = obj.region_id or 0
    if not is_region_visible(st, region_id) then
        return false, "obj not visible"
    end
    if owner_id == 0 then
        if not world:is_public_region_opened(region_id) then
            return false, "public region not opened"
        end
    else
        local p = st.region_progress[region_id]
        if p and p.cleared then
            return false, "private region already cleared"
        end
    end
    return true
end

local function aoi_obj_visible(st, world, obj)
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
    local layer = obj.visibility_layer or 2
    local region_id = obj.region_id or 0
    if layer == 1 or owner_id ~= 0 then
        if owner_id ~= st.player_id then
            return false
        end
        if region_id ~= st.current_region_id then
            return false
        end
        local p = st.region_progress[region_id]
        if p and p.cleared then
            return false
        end
        return true
    end
    if not world:is_public_region_opened(region_id) then
        return false
    end
    return is_region_visible(st, region_id)
end

local function append_visible(monsters, items, marches, list, st, world, seen)
    for _, obj in ipairs(list or {}) do
        if aoi_object.is_observer(obj) then
            goto continue
        end
        local id = aoi_object.uid_of(obj) or obj.id
        if not id or seen[id] then
            goto continue
        end
        if not aoi_obj_visible(st, world, obj) then
            goto continue
        end
        seen[id] = true
        if obj.type == aoi_object.TYPE.MARCH then
            marches[#marches + 1] = march.pack_visible(obj, obj.owner_shard_id or (world and world.shard_id) or 0)
        elseif obj.type == aoi_object.TYPE.MONSTER then
            monsters[#monsters + 1] = {
                uid = id,
                x = obj.x,
                y = obj.y,
                kind = obj.kind or "",
                region_id = obj.region_id or 0,
                visibility_layer = obj.visibility_layer or 2,
                owner_player_id = obj.owner_player_id or 0,
            }
        elseif obj.type == aoi_object.TYPE.RESOURCE or obj.type == "item" then
            items[#items + 1] = {
                uid = id,
                x = obj.x,
                y = obj.y,
                item_id = obj.item_id or 0,
                count = obj.count or 1,
                region_id = obj.region_id or 0,
                visibility_layer = obj.visibility_layer or 2,
                owner_player_id = obj.owner_player_id or 0,
            }
        end
        ::continue::
    end
end

local function collect_visible(world, st)
    local monsters = {}
    local items = {}
    local marches = {}
    if not st or not st.current_scene_id or st.current_scene_id <= 0 or not world then
        return monsters, items, marches
    end
    local seen = {}
    append_visible(monsters, items, marches, world:list_surrounding(st.player_id), st, world, seen)
    return monsters, items, marches
end

local function notify_visible_sync(player_id, world, st)
    local monsters, items, marches = collect_visible(world, st)
    protocol_handler.send_to_player(player_id, "map_visible_sync_notify", {
        map_id = world and world.map_id or 0,
        region_id = st.current_region_id or 0,
        monsters = monsters,
        items = items,
        marches = marches,
    })
end

local function notify_visible_sync_to_players(player_ids, world)
    for _, player_id in ipairs(player_ids or {}) do
        local st = M.player_state[player_id]
        if st and world and st.current_map_id == world.map_id then
            notify_visible_sync(player_id, world, st)
        end
    end
end

local function notify_players_around(world, x, y)
    if not world then
        return
    end
    local seen = {}
    for _, obj in ipairs(world:around(x, y, MAP_VIEW_RANGE)) do
        if aoi_object.is_observer(obj) then
            local pid = obj.player_id or aoi_object.uid_of(obj)
            pid = tonumber(pid) or pid
            if pid and not seen[pid] then
                seen[pid] = true
                local st = M.player_state[pid]
                if st and st.current_scene_id and st.current_scene_id > 0 and st.current_map_id == world.map_id then
                    notify_visible_sync(pid, world, st)
                end
            end
        end
    end
end

local function ensure_region_progress(st, region_id)
    local p = st.region_progress[region_id]
    if not p then
        p = { unlocked = false, explored = false, cleared = false, monster_left = 0, item_left = 0 }
        st.region_progress[region_id] = p
    end
    return p
end

local function recalc_region_left(world, st, region_id)
    local monster_left = 0
    local private_monsters = ((M.player_private_monsters[st.player_id] or {})[world.map_id]) or {}
    for _, m in pairs(private_monsters) do
        if m.alive and m.region_id == region_id then
            monster_left = monster_left + 1
        end
    end
    local item_left = 0
    local private_items = ((M.player_private_items[st.player_id] or {})[world.map_id]) or {}
    for _, it in pairs(private_items) do
        if it.alive and it.region_id == region_id then
            item_left = item_left + 1
        end
    end
    local p = ensure_region_progress(st, region_id)
    p.monster_left = monster_left
    p.item_left = item_left
    local was_cleared = p.cleared
    p.cleared = (monster_left == 0 and item_left == 0)
    return was_cleared, p.cleared
end

local function maybe_clear_region(world, st, region_id, player_id)
    local was_cleared, now_cleared = recalc_region_left(world, st, region_id)
    if (not was_cleared) and now_cleared then
        notify_region_cleared(world.map_id, region_id, player_id, "private")
        notify_flow(player_id, world.map_id, "private_region_cleared", region_id)
        notify_flow(player_id, world.map_id, "region_cleared", region_id)
        notify_visible_sync(player_id, world, st)

        if world:open_public_region(region_id) then
            for _, sid in ipairs(shard.all_ids()) do
                if sid ~= world.shard_id then
                    local addr = shard.addr(world.map_id, sid)
                    if addr then
                        skynet.send(addr, "lua", "on_peer_open_public_region", region_id)
                    end
                end
            end
            notify_region_cleared(world.map_id, region_id, player_id, "public")
            local visible_players = get_players_visible_region(world.map_id, region_id)
            for _, viewer_id in ipairs(visible_players) do
                local vst = M.player_state[viewer_id]
                if vst then
                    local explored_count, total_region_count, fog_percent = summarize_progress(vst, world)
                    notify_flow(viewer_id, world.map_id, "public_region_opened", region_id, {
                        explored_region_count = explored_count,
                        total_region_count = total_region_count,
                        fog_percent = fog_percent,
                        key_count = vst.key_count or 0,
                    })
                end
            end
            notify_visible_sync_to_players(visible_players, world)
        end

        local all_cleared = true
        local total = math.max(1, tonumber(world.def.region_count) or 1)
        for rid = 1, total do
            local p = st.region_progress[rid]
            if not (p and p.cleared) then
                all_cleared = false
                break
            end
        end
        if all_cleared then
            notify_flow(player_id, world.map_id, "map_completed", region_id)
        end
    end
end

local function start_world_save_timer()
    local function tick()
        skynet.timeout(WORLD_SAVE_INTERVAL, tick)
        map_store.flush()
    end
    skynet.timeout(WORLD_SAVE_INTERVAL, tick)
end

local function start_march_timer()
    local function tick()
        skynet.timeout(MARCH_TICK, tick)
        local ok, err = pcall(function()
            M.tick_marches()
        end)
        if not ok then
            log.error("march tick failed: %s", tostring(err))
        end
    end
    skynet.timeout(MARCH_TICK, tick)
end

function M.init()
    if M._inited then
        return true
    end
    M._inited = true
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
    M.map = Map.new(def, shard_id)
    M.map.on_aoi_changed = function(x, y, etype)
        if etype == aoi_object.TYPE.OBSERVER then
            return
        end
        notify_players_around(M.map, x, y)
    end
    M.map:bootstrap()
    start_world_save_timer()
    start_march_timer()
    log.info("Map service initialized, map_id=%s shard_id=%s", tostring(map_id), tostring(shard_id))
    return true
end

function M.enter_map(player_id, player_name, map_id)
    local world = get_map(map_id)
    if not world then
        return false, "map not found"
    end

    local st = get_or_init_player_state(player_id)
    st.player_id = player_id
    local old_map_id = st.current_map_id or 0
    local old_map = get_map(old_map_id)
    if st.current_scene_id and st.current_scene_id > 0 and old_map then
        pcall(function()
            old_map:leave_obj(player_id)
        end)
    end
    if old_map then
        detach_private_objs(old_map, player_id)
    end

    if not world:ensure_aoi() then
        return false, "ensure aoi failed"
    end

    st.player_name = player_name or st.player_name or ("Player_" .. tostring(player_id))
    local start = world.def.start or {}
    local x, y
    if start.x and start.y and world:owns_pos(start.x, start.y) then
        x, y = start.x, start.y
    else
        x, y = world:rand_spawn()
    end
    local observer = aoi_object.Observer.new({
        uid = tostring(player_id),
        player_id = player_id,
        player_name = st.player_name,
        x = x,
        y = y,
        view_range = MAP_VIEW_RANGE,
        map_id = map_id,
        shard_id = world.shard_id,
        owner_shard_id = world.shard_id,
        is_ghost = false,
    })
    local enter_ok, enter_err = world:enter_obj(observer)
    if not enter_ok then
        return false, enter_err or "enter aoi failed"
    end

    st.current_map_id = map_id
    st.current_scene_id = map_id
    st.x = x
    st.y = y
    st.region_progress = {}
    local region_id = world:region_id(x, y)
    st.current_region_id = region_id
    st.region_progress[region_id] = st.region_progress[region_id] or {
        unlocked = true,
        explored = true,
        cleared = false,
    }
    ensure_player_private_monsters(player_id, world)
    ensure_player_private_items(player_id, world)
    attach_private_objs(world, player_id)
    local explored_count, total_region_count, fog_percent = summarize_progress(st, world)
    for rid, _ in pairs(st.region_progress) do
        recalc_region_left(world, st, rid)
    end
    local monsters, items, marches = collect_visible(world, st)
    notify_visible_sync(player_id, world, st)
    notify_flow(player_id, map_id, "entered_map", region_id, {
        explored_region_count = explored_count,
        total_region_count = total_region_count,
        fog_percent = fog_percent,
        key_count = st.key_count or 0,
    })

    return true, with_shard(world, {
        map_id = map_id,
        scene_id = map_id,
        x = x,
        y = y,
        region_id = region_id,
        explored_region_count = explored_count,
        total_region_count = total_region_count,
        fog_percent = fog_percent,
        key_count = st.key_count or 0,
        monsters = monsters,
        items = items,
        marches = marches,
    })
end

function M.move(player_id, x, y)
    local st = get_or_init_player_state(player_id)
    local world = current_map(st)
    if not world or not st.current_scene_id or st.current_scene_id <= 0 then
        return false, "player not in map"
    end
    local old_region_id = st.current_region_id
    local region_id = world:region_id(x, y)
    if old_region_id ~= 0 and region_id ~= old_region_id then
        if not world:is_adjacent_region(old_region_id, region_id) then
            return false, "只能前往相邻区域"
        end
        local target_progress = ensure_region_progress(st, region_id)
        if not target_progress.unlocked then
            return false, "目标区域未解锁"
        end
    end
    local dest_shard = shard.shard_id_of_pos(x, y, world.def)
    if dest_shard ~= world.shard_id then
        if M.player_battles[player_id] then
            return false, "战斗中无法跨区"
        end
        return M.handoff_to_shard(player_id, dest_shard, x, y, region_id)
    end
    local ok, err = world:move_obj(player_id, x, y)
    if not ok then
        return false, err or "move failed"
    end
    st.x = x
    st.y = y
    st.current_region_id = region_id
    if region_id > 0 then
        local p = st.region_progress[region_id]
        if not p then
            st.region_progress[region_id] = { unlocked = true, explored = true, cleared = false, monster_left = 0, item_left = 0 }
        elseif not p.explored then
            p.explored = true
        end
        recalc_region_left(world, st, region_id)
    end
    local explored_count, total_region_count, fog_percent = summarize_progress(st, world)
    if old_region_id ~= region_id then
        protocol_handler.send_to_player(player_id, "map_progress_notify", {
            map_id = world.map_id,
            region_id = region_id,
            explored_region_count = explored_count,
            total_region_count = total_region_count,
            fog_percent = fog_percent,
        })
    end
    notify_visible_sync(player_id, world, st)
    return true, with_shard(world, {
        map_id = world.map_id,
        region_id = region_id,
        x = x,
        y = y,
        explored_region_count = explored_count,
        total_region_count = total_region_count,
        fog_percent = fog_percent,
        key_count = st.key_count or 0,
    })
end

function M.interact_monster(player_id, monster_uid)
    cleanup_expired_locks()
    cleanup_stale_battles()
    local st = get_or_init_player_state(player_id)
    local world = current_map(st)
    if not world then
        return false, "player not in map"
    end

    local uid = tostring(monster_uid or "")
    if uid == "" then
        return false, "monster_uid is required"
    end
    if M.player_battles[player_id] then
        return false, "battle already in progress"
    end
    local private_monsters = ((M.player_private_monsters[player_id] or {})[world.map_id]) or {}
    local monster = private_monsters[uid] or world:get_public_monster(uid)
    if monster then
        local can_interact, why = can_interact_obj(st, world, monster)
        if not can_interact then
            return false, why
        end
        if not monster.alive then
            return false, "monster already defeated"
        end
        if not in_attack_range(st.x, st.y, monster.x, monster.y, MAP_ATTACK_RANGE) then
            return false, "超出攻击范围"
        end
        local lock_key = "monster:" .. tostring(world.map_id) .. ":" .. uid
        if not acquire_lock(lock_key) then
            return false, "monster is busy"
        end
        hold_lock(lock_key)

        local ok, result_or_err = start_monster_instance(world, player_id, uid)
        if not ok then
            release_lock(lock_key)
            return false, result_or_err or "start monster instance failed"
        end

        M.player_battles[player_id] = {
            map_id = world.map_id,
            monster_uid = uid,
            lock_key = lock_key,
            inst_id = result_or_err.inst_id,
            start_tick = skynet.now(),
            deadline_tick = skynet.now() + BATTLE_TIMEOUT_TICK,
        }

        return true, with_shard(world, {
            map_id = world.map_id,
            monster_uid = uid,
            battle_type = "monster_instance",
            inst_id = result_or_err.inst_id or "",
            scene_id = result_or_err.scene_id or 0,
            result = "accepted",
        })
    end

    local ghost = world:get_obj(uid)
    local owner_shard_id = ghost and tonumber(ghost.owner_shard_id)
    local ctx = {
        player_id = player_id,
        x = st.x,
        y = st.y,
        attack_range = MAP_ATTACK_RANGE,
        current_region_id = st.current_region_id,
        region_progress = st.region_progress,
    }
    local function accept_remote(nid, result)
        M.player_battles[player_id] = {
            map_id = world.map_id,
            monster_uid = uid,
            lock_key = nil,
            owner_shard_id = result.owner_shard_id or nid,
            inst_id = result.inst_id,
            start_tick = skynet.now(),
            deadline_tick = skynet.now() + BATTLE_TIMEOUT_TICK,
            remote = true,
        }
        return true, result
    end
    local function call_owner(nid)
        local addr = shard.addr(world.map_id, nid)
        if not addr then
            return false, "目标战区不可用"
        end
        return skynet.call(addr, "lua", "try_interact_public", uid, ctx)
    end
    local tried = {}
    if owner_shard_id ~= nil and owner_shard_id ~= world.shard_id then
        tried[owner_shard_id] = true
        local ok, result = call_owner(owner_shard_id)
        if ok then
            return accept_remote(owner_shard_id, result)
        elseif result ~= "monster not found" and result ~= "map not found" then
            return false, result
        end
    end
    for _, nid in ipairs(world:neighbor_ids()) do
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

function M.on_battle_result(player_id, monster_uid, win)
    cleanup_expired_locks()
    cleanup_stale_battles()
    local st = get_or_init_player_state(player_id)
    local uid = tostring(monster_uid or "")
    local battle = M.player_battles[player_id]
    if not battle then
        return false, "battle context not found"
    end
    if uid == "" then
        uid = battle.monster_uid
    end
    if uid ~= battle.monster_uid then
        if battle.remote then
            cancel_owner_battle(current_map(st), player_id, battle.owner_shard_id, battle.monster_uid)
        elseif battle.lock_key then
            release_lock(battle.lock_key)
        end
        M.player_battles[player_id] = nil
        return false, "monster uid mismatch"
    end

    if battle.remote and battle.owner_shard_id ~= nil then
        local world = current_map(st)
        local addr = world and shard.addr(world.map_id, battle.owner_shard_id)
        if not addr then
            M.player_battles[player_id] = nil
            return false, "目标战区不可用"
        end
        local ok, result = skynet.call(addr, "lua", "apply_battle_result", player_id, uid, win and true or false)
        M.player_battles[player_id] = nil
        if not ok then
            skynet.send(addr, "lua", "cancel_remote_battle", player_id, uid)
            return false, result
        end
        notify_visible_sync(player_id, world, st)
        return true, result
    end

    local world = get_map(battle.map_id)
    local private_monsters = ((M.player_private_monsters[player_id] or {})[battle.map_id]) or {}
    local monster = private_monsters[uid] or (world and world:get_public_monster(uid))
    if not monster then
        if battle.lock_key then
            release_lock(battle.lock_key)
        end
        M.player_battles[player_id] = nil
        return false, "monster not found"
    end

    if win then
        monster.alive = false
        if world then
            world:detach(monster)
            if (monster.owner_player_id or 0) == 0 then
                world:save(monster)
            end
            notify_monster_removed(battle.map_id, monster.region_id or 0, uid, monster.x, monster.y, player_id)
            maybe_clear_region(world, st, monster.region_id or 0, player_id)
        end
    end
    if battle.lock_key then
        release_lock(battle.lock_key)
    end
    M.player_battles[player_id] = nil

    return true, with_shard(world, {
        map_id = battle.map_id or st.current_map_id,
        monster_uid = uid,
        win = win and true or false,
        removed = win and true or false,
    })
end

function M.pick_item(player_id, item_uid)
    cleanup_expired_locks()
    local st = get_or_init_player_state(player_id)
    local world = current_map(st)
    if not world then
        return false, "player not in map"
    end
    local uid = tostring(item_uid or "")
    if uid == "" then
        return false, "item_uid is required"
    end
    local private_items = ((M.player_private_items[player_id] or {})[world.map_id]) or {}
    local public_items = world:public_items()
    local item = private_items[uid] or public_items[uid]
    if not item then
        local ctx = {
            player_id = player_id,
            current_region_id = st.current_region_id,
            region_progress = st.region_progress,
        }
        for _, nid in ipairs(world:neighbor_ids()) do
            local addr = shard.addr(world.map_id, nid)
            if addr then
                local ok, result = skynet.call(addr, "lua", "try_pick_public", uid, ctx)
                if ok then
                    if result.item_id == 10003 then
                        st.key_count = (st.key_count or 0) + (result.count or 1)
                    end
                    result.key_count = st.key_count or 0
                    notify_visible_sync(player_id, world, st)
                    return true, result
                elseif result ~= "item not found" and result ~= "map not found" then
                    return false, result
                end
            end
        end
        return false, "item not found"
    end
    local can_interact, why = can_interact_obj(st, world, item)
    if not can_interact then
        return false, why
    end
    if not item.alive then
        return false, "item already picked"
    end
    local lock_key = "item:" .. tostring(world.map_id) .. ":" .. uid
    if not acquire_lock(lock_key) then
        return false, "item is busy"
    end
    item.alive = false
    if item.item_id == 10003 then
        st.key_count = (st.key_count or 0) + (item.count or 1)
    end
    world:detach(item)
    if public_items[uid] and not world:is_items_ephemeral() then
        world:save_item(item)
    end
    notify_item_removed(world.map_id, item.region_id or 0, uid, item.x, item.y, player_id)
    maybe_clear_region(world, st, item.region_id or 0, player_id)
    release_lock(lock_key)
    return true, with_shard(world, {
        map_id = world.map_id,
        item_uid = uid,
        item_id = item.item_id,
        count = item.count,
        key_count = st.key_count or 0,
        removed = true,
    })
end

function M.leave_map(player_id)
    M.despawn_player_marches(player_id)
    local st = M.player_state[player_id]
    if not st then
        return true
    end
    local map_id = st.current_map_id or 0
    local world = get_map(map_id)
    if st.current_scene_id and st.current_scene_id > 0 and world then
        pcall(function()
            world:leave_obj(player_id)
        end)
    end
    if world then
        detach_private_objs(world, player_id)
    end
    st.current_map_id = 0
    st.current_scene_id = 0
    st.current_region_id = 0
    local battle = M.player_battles[player_id]
    if battle then
        if battle.remote then
            cancel_owner_battle(world, player_id, battle.owner_shard_id, battle.monster_uid)
        elseif battle.lock_key then
            release_lock(battle.lock_key)
        end
    end
    M.player_battles[player_id] = nil
    local remote = M.remote_battles[player_id]
    if remote and remote.lock_key then
        release_lock(remote.lock_key)
    end
    M.remote_battles[player_id] = nil
    M.flow_notify_cache[player_id] = nil
    map_store.flush()
    return true
end

function M.sync_player_view(player_id)
    cleanup_expired_locks()
    cleanup_stale_battles()
    local st = get_or_init_player_state(player_id)
    local world = current_map(st)
    if not world then
        return false, "player not in map"
    end
    notify_visible_sync(player_id, world, st)
    return true, M.get_state(player_id)
end

function M.get_state(player_id)
    local st = get_or_init_player_state(player_id)
    local world = current_map(st)
    local explored_count, total_region_count, fog_percent = summarize_progress(st, world)
    local monsters, items, marches = {}, {}, {}
    if world then
        monsters, items, marches = collect_visible(world, st)
    end
    return with_shard(world, {
        map_id = st.current_map_id or 0,
        scene_id = st.current_scene_id or 0,
        region_id = st.current_region_id or 0,
        x = st.x or 0,
        y = st.y or 0,
        explored_region_count = explored_count,
        total_region_count = total_region_count,
        fog_percent = fog_percent,
        key_count = st.key_count or 0,
        monsters = monsters,
        items = items,
        marches = marches,
    })
end

function M.unlock_region(player_id, region_id)
    local st = get_or_init_player_state(player_id)
    local world = current_map(st)
    if not world then
        return false, "player not in map"
    end
    local rid = tonumber(region_id) or 0
    if rid <= 0 then
        return false, "invalid region_id"
    end
    if not world:is_adjacent_region(st.current_region_id, rid) then
        return false, "只能解锁相邻区域"
    end
    local p = ensure_region_progress(st, rid)
    if p.unlocked then
        return true, with_shard(world, {
            map_id = world.map_id,
            region_id = rid,
            key_count = st.key_count or 0,
        })
    end
    if (st.key_count or 0) <= 0 then
        return false, "钥匙不足"
    end
    st.key_count = st.key_count - 1
    p.unlocked = true
    notify_region_unlocked(player_id, world.map_id, rid, st.key_count)
    notify_flow(player_id, world.map_id, "region_unlocked", rid, { key_count = st.key_count })
    return true, with_shard(world, {
        map_id = world.map_id,
        region_id = rid,
        key_count = st.key_count,
    })
end

local function export_player(player_id)
    local st = M.player_state[player_id]
    local world = current_map(st)
    if not st or not world then
        return nil, "player not in map"
    end
    local map_id = world.map_id
    local snap = {
        player_id = player_id,
        player_name = st.player_name,
        x = st.x,
        y = st.y,
        key_count = st.key_count or 0,
        current_region_id = st.current_region_id or 0,
        region_progress = copy_table(st.region_progress),
        private_monsters = copy_table((M.player_private_monsters[player_id] or {})[map_id]),
        private_items = copy_table((M.player_private_items[player_id] or {})[map_id]),
    }
    detach_private_objs(world, player_id)
    if st.current_scene_id and st.current_scene_id > 0 then
        pcall(function()
            world:leave_obj(player_id)
        end)
    end
    if M.player_private_monsters[player_id] then
        M.player_private_monsters[player_id][map_id] = nil
    end
    if M.player_private_items[player_id] then
        M.player_private_items[player_id][map_id] = nil
    end
    st.current_map_id = 0
    st.current_scene_id = 0
    M.flow_notify_cache[player_id] = nil
    return snap
end

function M.handoff_to_shard(player_id, dest_shard, x, y, region_id)
    local st = M.player_state[player_id]
    local world = current_map(st)
    if not world then
        return false, "player not in map"
    end
    local old_x, old_y = st.x, st.y
    local old_region = st.current_region_id
    local dest = shard.addr(world.map_id, dest_shard)
    if not dest then
        return false, "目标战区不可用"
    end
    local snap = export_player(player_id)
    if not snap then
        return false, "export player failed"
    end
    snap.x = x
    snap.y = y
    snap.current_region_id = region_id
    local ok, result = skynet.call(dest, "lua", "accept_handoff", snap)
    if not ok then
        snap.x = old_x
        snap.y = old_y
        snap.current_region_id = old_region
        local restored, restore_err = M.accept_handoff(snap)
        if not restored then
            log.error("handoff rollback failed, player_id=%s err=%s", tostring(player_id), tostring(restore_err))
        end
        return false, result or "跨区失败"
    end
    return true, result
end

function M.accept_handoff(snap)
    local world = M.map
    if not world then
        return false, "map not found"
    end
    local player_id = snap and snap.player_id
    if not player_id then
        return false, "invalid handoff"
    end
    if not world:owns_pos(snap.x, snap.y) then
        return false, "pos not in this shard"
    end
    if not world:ensure_aoi() then
        return false, "ensure aoi failed"
    end
    local st = get_or_init_player_state(player_id)
    st.player_id = player_id
    st.player_name = snap.player_name or st.player_name or ("Player_" .. tostring(player_id))
    local observer = aoi_object.Observer.new({
        uid = tostring(player_id),
        player_id = player_id,
        player_name = st.player_name,
        x = snap.x,
        y = snap.y,
        view_range = MAP_VIEW_RANGE,
        map_id = world.map_id,
        shard_id = world.shard_id,
        owner_shard_id = world.shard_id,
        is_ghost = false,
    })
    local enter_ok, enter_err = world:enter_obj(observer)
    if not enter_ok then
        return false, enter_err or "enter aoi failed"
    end
    st.current_map_id = world.map_id
    st.current_scene_id = world.map_id
    st.x = snap.x
    st.y = snap.y
    st.key_count = snap.key_count or 0
    st.region_progress = snap.region_progress or st.region_progress or {}
    st.current_region_id = snap.current_region_id or world:region_id(snap.x, snap.y)
    local by_m = M.player_private_monsters[player_id] or {}
    M.player_private_monsters[player_id] = by_m
    by_m[world.map_id] = snap.private_monsters or by_m[world.map_id] or {}
    local by_i = M.player_private_items[player_id] or {}
    M.player_private_items[player_id] = by_i
    by_i[world.map_id] = snap.private_items or by_i[world.map_id] or {}
    attach_private_objs(world, player_id)
    if st.current_region_id > 0 then
        local p = st.region_progress[st.current_region_id]
        if not p then
            st.region_progress[st.current_region_id] = { unlocked = true, explored = true, cleared = false, monster_left = 0, item_left = 0 }
        elseif not p.explored then
            p.explored = true
        end
        recalc_region_left(world, st, st.current_region_id)
    end
    local explored_count, total_region_count, fog_percent = summarize_progress(st, world)
    local monsters, items, marches = collect_visible(world, st)
    notify_flow(player_id, world.map_id, "entered_map", st.current_region_id, {
        explored_region_count = explored_count,
        total_region_count = total_region_count,
        fog_percent = fog_percent,
        key_count = st.key_count or 0,
    })
    return true, with_shard(world, {
        map_id = world.map_id,
        scene_id = world.map_id,
        x = st.x,
        y = st.y,
        region_id = st.current_region_id,
        explored_region_count = explored_count,
        total_region_count = total_region_count,
        fog_percent = fog_percent,
        key_count = st.key_count or 0,
        monsters = monsters,
        items = items,
        marches = marches,
    })
end

function M.ghost_upsert(payload)
    local world = M.map
    if not world or not payload then
        return
    end
    world:apply_ghost_upsert(payload)
end

function M.ghost_remove(uid, _x, _y)
    local world = M.map
    if not world then
        return
    end
    world:apply_ghost_remove(uid)
end

function M.try_pick_public(uid, ctx)
    cleanup_expired_locks()
    local world = M.map
    if not world then
        return false, "map not found"
    end
    uid = tostring(uid or "")
    if uid == "" or type(ctx) ~= "table" then
        return false, "item not found"
    end
    local item = world:get_public_item(uid)
    if not item then
        return false, "item not found"
    end
    local st = {
        player_id = ctx.player_id,
        current_region_id = ctx.current_region_id,
        region_progress = ctx.region_progress or {},
    }
    local can_interact, why = can_interact_obj(st, world, item)
    if not can_interact then
        return false, why
    end
    if not item.alive then
        return false, "item already picked"
    end
    local lock_key = "item:" .. tostring(world.map_id) .. ":" .. uid
    if not acquire_lock(lock_key) then
        return false, "item is busy"
    end
    item.alive = false
    world:detach(item)
    if not world:is_items_ephemeral() then
        world:save_item(item)
    end
    notify_item_removed(world.map_id, item.region_id or 0, uid, item.x, item.y, ctx.player_id)
    release_lock(lock_key)
    return true, with_shard(world, {
        map_id = world.map_id,
        item_uid = uid,
        item_id = item.item_id,
        count = item.count,
        region_id = item.region_id or 0,
        removed = true,
    })
end

function M.try_interact_public(uid, ctx)
    cleanup_expired_locks()
    cleanup_stale_battles()
    local world = M.map
    if not world then
        return false, "map not found"
    end
    uid = tostring(uid or "")
    if uid == "" or type(ctx) ~= "table" or not ctx.player_id then
        return false, "monster not found"
    end
    local player_id = ctx.player_id
    if M.remote_battles[player_id] or M.player_battles[player_id] then
        return false, "battle already in progress"
    end
    local monster = world:get_public_monster(uid)
    if not monster then
        return false, "monster not found"
    end
    local st = {
        player_id = player_id,
        current_region_id = ctx.current_region_id,
        region_progress = ctx.region_progress or {},
    }
    local can_interact, why = can_interact_obj(st, world, monster)
    if not can_interact then
        return false, why
    end
    if not monster.alive then
        return false, "monster already defeated"
    end
    local px, py = tonumber(ctx.x), tonumber(ctx.y)
    if not px or not py then
        local attacker = world:get_obj(player_id)
        if attacker then
            px, py = attacker.x, attacker.y
        end
    end
    if not in_attack_range(px, py, monster.x, monster.y, ctx.attack_range or MAP_ATTACK_RANGE) then
        return false, "超出攻击范围"
    end
    local lock_key = "monster:" .. tostring(world.map_id) .. ":" .. uid
    if not acquire_lock(lock_key) then
        return false, "monster is busy"
    end
    hold_lock(lock_key)
    local ok, result_or_err = start_monster_instance(world, player_id, uid)
    if not ok then
        release_lock(lock_key)
        return false, result_or_err or "start monster instance failed"
    end
    M.remote_battles[player_id] = {
        map_id = world.map_id,
        monster_uid = uid,
        lock_key = lock_key,
        inst_id = result_or_err.inst_id,
        start_tick = skynet.now(),
        deadline_tick = skynet.now() + BATTLE_TIMEOUT_TICK,
    }
    return true, with_shard(world, {
        map_id = world.map_id,
        monster_uid = uid,
        battle_type = "monster_instance",
        inst_id = result_or_err.inst_id or "",
        scene_id = result_or_err.scene_id or 0,
        result = "accepted",
        owner_shard_id = world.shard_id,
    })
end

function M.apply_battle_result(player_id, monster_uid, win)
    cleanup_expired_locks()
    cleanup_stale_battles()
    local world = M.map
    if not world then
        return false, "map not found"
    end
    local uid = tostring(monster_uid or "")
    local battle = M.remote_battles[player_id]
    if not battle then
        return false, "battle context not found"
    end
    if uid == "" then
        uid = battle.monster_uid
    end
    if uid ~= battle.monster_uid then
        return false, "monster uid mismatch"
    end
    local monster = world:get_public_monster(uid)
    if not monster then
        if battle.lock_key then
            release_lock(battle.lock_key)
        end
        M.remote_battles[player_id] = nil
        return false, "monster not found"
    end
    if win then
        monster.alive = false
        world:detach(monster)
        world:save(monster)
        notify_monster_removed(world.map_id, monster.region_id or 0, uid, monster.x, monster.y, player_id)
        protocol_handler.send_to_player(player_id, "map_monster_removed_notify", {
            map_id = world.map_id,
            monster_uid = uid,
            x = monster.x or 0,
            y = monster.y or 0,
            killer_player_id = player_id or 0,
        })
    end
    if battle.lock_key then
        release_lock(battle.lock_key)
    end
    M.remote_battles[player_id] = nil
    return true, with_shard(world, {
        map_id = world.map_id,
        monster_uid = uid,
        win = win and true or false,
        removed = win and true or false,
    })
end

function M.cancel_remote_battle(player_id, monster_uid)
    local battle = M.remote_battles[player_id]
    if not battle then
        return true
    end
    if monster_uid and tostring(monster_uid) ~= "" and tostring(monster_uid) ~= tostring(battle.monster_uid) then
        return true
    end
    if battle.lock_key then
        release_lock(battle.lock_key)
    end
    M.remote_battles[player_id] = nil
    return true
end

function M.on_peer_open_public_region(region_id)
    local world = M.map
    if not world then
        return
    end
    if not world:open_public_region(region_id, false) then
        return
    end
    local visible_players = get_players_visible_region(world.map_id, region_id)
    notify_visible_sync_to_players(visible_players, world)
end

local function index_player_march(player_id, uid)
    if not player_id or not uid then
        return
    end
    local t = M.player_marches[player_id]
    if not t then
        t = {}
        M.player_marches[player_id] = t
    end
    t[uid] = true
end

local function unindex_player_march(player_id, uid)
    local t = M.player_marches[player_id]
    if t then
        t[uid] = nil
    end
end

local function count_player_marches(player_id)
    local n = 0
    local t = M.player_marches[player_id]
    if not t then
        return 0
    end
    for uid, _ in pairs(t) do
        if M.marches[uid] then
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
    local world = M.map
    if not world then
        return n
    end
    for _, sid in ipairs(shard.all_ids()) do
        if sid ~= world.shard_id then
            local addr = shard.addr(world.map_id, sid)
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
        local m = M.marches[march_uid]
        if m and m.owner_player_id == player_id then
            return m
        end
        return nil
    end
    local t = M.player_marches[player_id]
    if not t then
        return nil
    end
    for uid, _ in pairs(t) do
        local m = M.marches[uid]
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

local function notify_march_sync(world, m, removed)
    if not m then
        return
    end
    local payload = {
        map_id = world and world.map_id or 0,
        marches = (not removed) and { march.pack_visible(m, world and world.shard_id) } or {},
        removed_uid = removed and (m.uid or "") or "",
        shard_id = world and world.shard_id or 0,
    }
    if m.owner_player_id then
        protocol_handler.send_to_player(m.owner_player_id, "map_march_sync_notify", payload)
    end
end

local function notify_field_battle(world, battle, phase, extra)
    if not battle then
        return
    end
    extra = extra or {}
    local msg = {
        map_id = world and world.map_id or 0,
        battle_id = battle.id or "",
        phase = phase or "",
        attacker_uid = battle.attacker_uid or "",
        defender_uid = battle.defender_uid or "",
        attacker_hp = extra.attacker_hp or 0,
        defender_hp = extra.defender_hp or 0,
        reason = extra.reason or "",
        shard_id = world and world.shard_id or 0,
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
    if keep_chase and m.target_uid and m.alive then
        m.state = march.STATE_CHASE
    else
        m.state = march.STATE_MARCHING
        if not keep_chase then
            m.target_uid = nil
        end
    end
end

local end_field_battle
local despawn_march

local function query_sid_march(world, sid, uid)
    if not world or sid == nil or sid == world.shard_id then
        return nil
    end
    local addr = shard.addr(world.map_id, sid)
    if not addr then
        return nil
    end
    local ok, snap = skynet.call(addr, "lua", "query_march", uid)
    if ok and type(snap) == "table" then
        return snap
    end
    return nil
end

local function resolve_target(world, uid, hint_shard)
    uid = tostring(uid or "")
    if uid == "" or not world then
        return nil
    end
    local local_m = M.marches[uid]
    if local_m and local_m.alive then
        return {
            uid = uid,
            x = local_m.x,
            y = local_m.y,
            hp = local_m.hp,
            max_hp = local_m.max_hp,
            owner_player_id = local_m.owner_player_id,
            shard_id = world.shard_id,
            battle_id = local_m.battle_id or "",
            local_march = local_m,
        }
    end
    local ghost = march.from_ghost(world:get_obj(uid))
    local snap = query_sid_march(world, hint_shard, uid)
    if not snap and ghost then
        snap = query_sid_march(world, ghost.shard_id, uid)
    end
    if not snap then
        for _, nid in ipairs(world:neighbor_ids()) do
            snap = query_sid_march(world, nid, uid)
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

local function start_field_battle(world, atk, target)
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
        defender_shard = target.shard_id or world.shard_id,
        host_shard = world.shard_id,
    }
    local def_local = target.local_march or M.marches[target.uid]
    if def_local then
        if def_local.battle_id then
            return false, "目标交战中"
        end
        def_local.battle_id = battle.id
        def_local.host_shard_id = world.shard_id
        def_local.role = "defender"
        def_local.state = march.STATE_BATTLE
    else
        local addr = shard.addr(world.map_id, battle.defender_shard)
        if not addr then
            return false, "目标战区不可用"
        end
        local ok, err = skynet.call(addr, "lua", "march_set_defender", target.uid, {
            battle_id = battle.id,
            host_shard = world.shard_id,
            attacker_uid = atk.uid,
            attacker_player_id = atk.owner_player_id,
        })
        if not ok then
            return false, err or "目标交战中"
        end
    end
    atk.battle_id = battle.id
    atk.host_shard_id = world.shard_id
    atk.role = "attacker"
    atk.state = march.STATE_BATTLE
    atk.target_uid = target.uid
    atk.target_shard_id = battle.defender_shard
    M.field_battles[battle.id] = battle
    notify_field_battle(world, battle, "engage", {
        attacker_hp = atk.hp or 0,
        defender_hp = target.hp or 0,
    })
    return true
end

end_field_battle = function(battle, reason)
    if not battle then
        return
    end
    local world = M.map
    if M.field_battles[battle.id] then
        M.field_battles[battle.id] = nil
    end
    local atk = M.marches[battle.attacker_uid]
    if atk then
        clear_march_battle_fields(atk, atk.target_uid and true or false)
    end
    local def = M.marches[battle.defender_uid]
    if def then
        clear_march_battle_fields(def, false)
    elseif world and battle.defender_shard ~= nil and battle.defender_shard ~= (world.shard_id) then
        local addr = shard.addr(world.map_id, battle.defender_shard)
        if addr then
            skynet.send(addr, "lua", "march_clear_battle", battle.defender_uid, battle.id, reason)
        end
    end
    notify_field_battle(world, battle, "end", { reason = reason or "" })
end

despawn_march = function(world, m, reason, skip_end_battle)
    if not m then
        return
    end
    if not skip_end_battle and m.battle_id then
        local battle = M.field_battles[m.battle_id]
        if battle then
            end_field_battle(battle, reason or "despawn")
        elseif world and m.host_shard_id and m.host_shard_id ~= world.shard_id then
            local addr = shard.addr(world.map_id, m.host_shard_id)
            if addr then
                skynet.send(addr, "lua", "end_hosted_battle", m.battle_id, reason or "despawn")
            end
        end
    end
    if world and m.in_aoi then
        pcall(function()
            world:leave_obj(m.uid)
        end)
        m.in_aoi = false
    end
    M.marches[m.uid] = nil
    unindex_player_march(m.owner_player_id, m.uid)
    remember_owner_march(m.owner_player_id, m.uid, world and world.shard_id, true)
    notify_march_sync(world, m, true)
end

local function attach_march_aoi(world, m)
    march.bind_map(m, world.map_id, world.shard_id)
    local ix = math.floor((m.x or 0) + 0.5)
    local iy = math.floor((m.y or 0) + 0.5)
    m.x, m.y = ix, iy
    local ok, err = world:enter_obj(m)
    if ok then
        m.in_aoi = true
        m.scene_x = ix
        m.scene_y = iy
        m.shard_id = world.shard_id
    end
    return ok, err
end

local function sync_march_aoi(world, m, force_notify)
    local ix = math.floor((m.x or 0) + 0.5)
    local iy = math.floor((m.y or 0) + 0.5)
    if m.in_aoi and (ix ~= m.scene_x or iy ~= m.scene_y) then
        world:move_obj(m.uid, ix, iy)
        m.scene_x, m.scene_y = ix, iy
    elseif m.in_aoi then
        -- hp/state 等非坐标变化仍要推 ghost
        world:sync_ghosts(m)
    end
    if force_notify or march.dist2(m.x, m.y, m.last_notify_x, m.last_notify_y) >= (march.NOTIFY_MOVE * march.NOTIFY_MOVE) then
        m.last_notify_x, m.last_notify_y = m.x, m.y
        notify_march_sync(world, m)
    end
end

local function try_handoff_march(world, m)
    local dest = shard.shard_id_of_pos(m.x, m.y, world.def)
    if dest == world.shard_id then
        return false
    end
    local addr = shard.addr(world.map_id, dest)
    if not addr then
        local x0, y0, x1, y1 = shard.pixel_rect(world.shard_id, world.def)
        m.x = math.max(x0, math.min(x1, m.x))
        m.y = math.max(y0, math.min(y1, m.y))
        return false
    end
    local snap = { march = march.export(m) }
    if m.role == "attacker" and m.battle_id then
        snap.battle = M.field_battles[m.battle_id]
    end
    if m.in_aoi then
        pcall(function()
            world:leave_obj(m.uid)
        end)
        m.in_aoi = false
    end
    M.marches[m.uid] = nil
    unindex_player_march(m.owner_player_id, m.uid)
    if snap.battle then
        M.field_battles[snap.battle.id] = nil
    end
    local ok, result = skynet.call(addr, "lua", "accept_march_handoff", snap)
    if not ok then
        m.x, m.y = march.clamp(world.def, m.x, m.y)
        if not world:owns_pos(m.x, m.y) then
            local x0, y0, x1, y1 = shard.pixel_rect(world.shard_id, world.def)
            m.x = math.max(x0, math.min(x1, m.x))
            m.y = math.max(y0, math.min(y1, m.y))
        end
        M.marches[m.uid] = m
        index_player_march(m.owner_player_id, m.uid)
        if snap.battle then
            M.field_battles[snap.battle.id] = snap.battle
        end
        attach_march_aoi(world, m)
        log.error("march handoff failed, uid=%s dest=%s err=%s", tostring(m.uid), tostring(dest), tostring(result))
        return false
    end
    remember_owner_march(m.owner_player_id, m.uid, dest, false)
    return true
end

local function find_world_path(world, x1, y1, x2, y2, keep_end)
    local addr = skynet.localname(PATHFINDING_NAME)
    if not addr then
        log.warning("pathfinding unavailable, fallback straight line")
        return { { x = x1, y = y1 }, { x = x2, y = y2 } }
    end
    local ok, result = skynet.call(addr, "lua", "find_path", world.map_id, x1, y1, x2, y2, keep_end and true or false)
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

local function maybe_repath_chase(world, m, tgt)
    local arrived = not (m.waypoints and m.waypoints[m.wp_index or 1])
    local need = arrived
    if m.last_path_tx and m.last_path_ty then
        if march.dist2(m.last_path_tx, m.last_path_ty, tgt.x, tgt.y) >= (CHASE_REPATH_DIST * CHASE_REPATH_DIST) then
            need = true
        end
    else
        need = true
    end
    if not need then
        return
    end
    local path = find_world_path(world, m.x, m.y, tgt.x, tgt.y, true)
    if not path then
        path = { { x = m.x, y = m.y }, { x = tgt.x, y = tgt.y } }
    end
    apply_march_path(m, path, tgt.x, tgt.y)
end

local function tick_one_march(world, m)
    local hold = (m.state == march.STATE_BATTLE and m.role == "defender")
    if m.state == march.STATE_CHASE or (m.state == march.STATE_BATTLE and m.role == "attacker") then
        local tgt = resolve_target(world, m.target_uid, m.target_shard_id)
        if tgt then
            m.target_shard_id = tgt.shard_id
            if not m.battle_id and march.in_range(m.x, m.y, tgt.x, tgt.y, march.ENGAGE_RANGE) then
                start_field_battle(world, m, tgt)
                hold = true
            elseif march.in_range(m.x, m.y, tgt.x, tgt.y, march.ENGAGE_RANGE) then
                hold = true
            else
                maybe_repath_chase(world, m, tgt)
            end
        end
    end
    if not hold then
        local tx, ty = march.current_dest(m)
        local nx, ny = march.step(m.x, m.y, tx, ty, m.speed, march.TICK_SEC)
        m.x, m.y = march.clamp(world.def, nx, ny)
        local wp = m.waypoints and m.waypoints[m.wp_index or 1]
        if wp and march.in_range(m.x, m.y, wp.x, wp.y, 1.5) then
            m.wp_index = (m.wp_index or 1) + 1
        end
    end
    if try_handoff_march(world, m) then
        return
    end
    sync_march_aoi(world, m)
end

local function tick_one_battle(world, battle)
    local atk = M.marches[battle.attacker_uid]
    if not atk or not atk.alive then
        end_field_battle(battle, "attacker_gone")
        return
    end
    local tgt = resolve_target(world, battle.defender_uid, battle.defender_shard)
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
    local def_hp = tgt.hp or 0
    local def_dead = false
    if tgt.local_march then
        tgt.local_march.hp = math.max(0, (tgt.local_march.hp or 0) - march.DAMAGE)
        def_hp = tgt.local_march.hp
        def_dead = def_hp <= 0
    else
        local addr = shard.addr(world.map_id, tgt.shard_id)
        if addr then
            local ok, result = skynet.call(addr, "lua", "apply_march_damage", tgt.uid, march.DAMAGE, battle.id)
            if ok and type(result) == "table" then
                def_hp = result.hp or 0
                def_dead = result.dead and true or false
            end
        end
    end
    notify_field_battle(world, battle, "tick", {
        attacker_hp = atk.hp or 0,
        defender_hp = def_hp,
    })
    if atk.in_aoi then
        world:sync_ghosts(atk)
    end
    if tgt.local_march and tgt.local_march.in_aoi then
        world:sync_ghosts(tgt.local_march)
    end
    if atk.hp <= 0 then
        end_field_battle(battle, "attacker_dead")
        despawn_march(world, atk, "dead", true)
    elseif def_dead then
        end_field_battle(battle, "defender_dead")
        if tgt.local_march then
            despawn_march(world, tgt.local_march, "dead", true)
        end
    end
end

function M.tick_marches()
    local world = M.map
    if not world then
        return
    end
    local uids = {}
    for uid, _ in pairs(M.marches) do
        uids[#uids + 1] = uid
    end
    for _, uid in ipairs(uids) do
        local m = M.marches[uid]
        if m and m.alive then
            tick_one_march(world, m)
        end
    end
    local bids = {}
    for id, _ in pairs(M.field_battles) do
        bids[#bids + 1] = id
    end
    for _, id in ipairs(bids) do
        local battle = M.field_battles[id]
        if battle then
            tick_one_battle(world, battle)
        end
    end
end

function M.despawn_player_marches(player_id)
    local world = M.map
    local t = M.player_marches[player_id]
    if not t then
        return
    end
    local uids = {}
    for uid, _ in pairs(t) do
        uids[#uids + 1] = uid
    end
    for _, uid in ipairs(uids) do
        local m = M.marches[uid]
        if m then
            despawn_march(world, m, "leave")
        end
    end
    M.player_marches[player_id] = nil
end

function M.march_start(player_id, x, y)
    local st = get_or_init_player_state(player_id)
    local world = current_map(st)
    if not world then
        return false, "player not in map"
    end
    if count_all_player_marches(player_id) >= march.MAX_PER_PLAYER then
        return false, "行军数量已满"
    end
    x, y = march.clamp(world.def, x, y)
    local path, path_err = find_world_path(world, st.x, st.y, x, y)
    if not path then
        return false, path_err or "无法到达目标"
    end
    local dest = path[#path]
    M.march_seq[player_id] = (M.march_seq[player_id] or 0) + 1
    local uid = string.format("m_%d_%d_%d", player_id, world.shard_id, M.march_seq[player_id])
    local m = march.new({
        uid = uid,
        owner_player_id = player_id,
        x = st.x,
        y = st.y,
        waypoints = path,
        shard_id = world.shard_id,
        state = march.STATE_MARCHING,
        last_path_tx = dest.x,
        last_path_ty = dest.y,
    })
    M.marches[uid] = m
    index_player_march(player_id, uid)
    local ok, err = attach_march_aoi(world, m)
    if not ok then
        M.marches[uid] = nil
        unindex_player_march(player_id, uid)
        return false, err or "行军进入场景失败"
    end
    remember_owner_march(player_id, uid, world.shard_id, false)
    notify_march_sync(world, m)
    return true, with_shard(world, {
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
    local world = M.map
    if not world then
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
    local tgt = resolve_target(world, target_uid, m.target_shard_id)
    if not tgt then
        return false, "目标不在范围内"
    end
    if tgt.owner_player_id == player_id then
        return false, "不能攻击自己的行军"
    end
    m.target_uid = target_uid
    m.target_shard_id = tgt.shard_id
    if not m.battle_id then
        m.state = march.STATE_CHASE
        if march.in_range(m.x, m.y, tgt.x, tgt.y, march.ENGAGE_RANGE) then
            local ok, err = start_field_battle(world, m, tgt)
            if not ok then
                return false, err
            end
        else
            local path = find_world_path(world, m.x, m.y, tgt.x, tgt.y, true)
            if not path then
                path = { { x = m.x, y = m.y }, { x = tgt.x, y = tgt.y } }
            end
            apply_march_path(m, path, tgt.x, tgt.y)
        end
    end
    notify_march_sync(world, m)
    return true, with_shard(world, {
        march_uid = m.uid,
        target_uid = target_uid,
        state = m.state,
        battle_id = m.battle_id or "",
    })
end

function M.march_cancel(player_id, march_uid)
    local world = M.map
    local m = pick_player_march(player_id, march_uid)
    if not m then
        return false, "march not found"
    end
    local uid = m.uid
    despawn_march(world, m, "cancel")
    return true, with_shard(world, {
        march_uid = uid,
        removed = true,
    })
end

function M.query_march(uid)
    local world = M.map
    local m = M.marches[tostring(uid or "")]
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
        shard_id = world and world.shard_id,
        battle_id = m.battle_id or "",
        state = m.state,
    }
end

function M.apply_march_damage(uid, dmg, battle_id)
    local world = M.map
    local m = M.marches[tostring(uid or "")]
    if not m then
        return false, "march not found"
    end
    if battle_id and m.battle_id and tostring(battle_id) ~= tostring(m.battle_id) then
        return false, "battle mismatch"
    end
    m.hp = math.max(0, (m.hp or 0) - (tonumber(dmg) or 0))
    if m.hp <= 0 then
        m.alive = false
        despawn_march(world, m, "dead", true)
        return true, { hp = 0, dead = true }
    end
    notify_march_sync(world, m)
    if world and m.in_aoi then
        world:sync_ghosts(m)
    end
    return true, { hp = m.hp, dead = false }
end

function M.march_set_defender(uid, info)
    local m = M.marches[tostring(uid or "")]
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
    return true
end

function M.march_clear_battle(uid, battle_id, _reason)
    local m = M.marches[tostring(uid or "")]
    if not m then
        return true
    end
    if battle_id and m.battle_id and tostring(m.battle_id) ~= tostring(battle_id) then
        return true
    end
    clear_march_battle_fields(m, false)
    return true
end

function M.march_update_host(uid, battle_id, host_shard)
    local m = M.marches[tostring(uid or "")]
    if m and (not battle_id or tostring(m.battle_id) == tostring(battle_id)) then
        m.host_shard_id = host_shard
    end
    return true
end

function M.battle_defender_moved(battle_id, dest_shard, _uid)
    local battle = M.field_battles[tostring(battle_id or "")]
    if battle then
        battle.defender_shard = dest_shard
    end
    return true
end

function M.end_hosted_battle(battle_id, reason)
    local battle = M.field_battles[tostring(battle_id or "")]
    if battle then
        end_field_battle(battle, reason or "remote_end")
    end
    return true
end

function M.accept_march_handoff(snap)
    local world = M.map
    if not world or type(snap) ~= "table" or type(snap.march) ~= "table" then
        return false, "invalid handoff"
    end
    local m = march.from_export(snap.march)
    m.x, m.y = march.clamp(world.def, m.x, m.y)
    if not world:owns_pos(m.x, m.y) then
        return false, "pos not in this shard"
    end
    m.shard_id = world.shard_id
    if m.role == "attacker" then
        m.host_shard_id = world.shard_id
    end
    M.marches[m.uid] = m
    index_player_march(m.owner_player_id, m.uid)
    local ok, err = attach_march_aoi(world, m)
    if not ok then
        M.marches[m.uid] = nil
        unindex_player_march(m.owner_player_id, m.uid)
        return false, err or "enter scene failed"
    end
    if snap.battle then
        snap.battle.host_shard = world.shard_id
        M.field_battles[snap.battle.id] = snap.battle
        if snap.battle.defender_shard ~= world.shard_id then
            local addr = shard.addr(world.map_id, snap.battle.defender_shard)
            if addr then
                skynet.send(addr, "lua", "march_update_host", snap.battle.defender_uid, snap.battle.id, world.shard_id)
            end
        else
            local def = M.marches[snap.battle.defender_uid]
            if def then
                def.host_shard_id = world.shard_id
            end
        end
    elseif m.role == "defender" and m.battle_id and m.host_shard_id then
        local addr = shard.addr(world.map_id, m.host_shard_id)
        if addr then
            skynet.send(addr, "lua", "battle_defender_moved", m.battle_id, world.shard_id, m.uid)
        end
    end
    remember_owner_march(m.owner_player_id, m.uid, world.shard_id, false)
    notify_march_sync(world, m, false)
    return true, with_shard(world, {
        march_uid = m.uid,
        x = math.floor(m.x + 0.5),
        y = math.floor(m.y + 0.5),
        shard_id = world.shard_id,
    })
end

return M
