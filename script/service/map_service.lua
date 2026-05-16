local skynet = require "skynet"
local log = require "log"
local service_ctx = require "runtime.service_ctx"
local protocol_handler = require "protocol_handler"

local M = service_ctx.get("map.map_service", {})
M._inited = M._inited or false
M.map_defs = M.map_defs or {}
M.player_state = M.player_state or {}
M.map_monsters = M.map_monsters or {}
M.map_items = M.map_items or {}
M.map_public_monsters = M.map_public_monsters or {}
M.map_public_items = M.map_public_items or {}
M.player_private_monsters = M.player_private_monsters or {}
M.player_private_items = M.player_private_items or {}
M.player_battles = M.player_battles or {}
M.flow_notify_cache = M.flow_notify_cache or {}
M.entity_locks = M.entity_locks or {}
M.public_region_opened = M.public_region_opened or {}

local BATTLE_TIMEOUT_TICK = 1800 -- 180s, skynet.now() tick=10ms

local function make_default_maps()
    return {
        [1001] = {
            map_id = 1001,
            name = "青云平原",
            width = 1000,
            height = 1000,
            grid_size = 50,
            region_count = 16,
            start = { x = 120, y = 120 },
        },
        [1002] = {
            map_id = 1002,
            name = "雾林遗迹",
            width = 1200,
            height = 1200,
            grid_size = 50,
            region_count = 20,
            start = { x = 150, y = 150 },
        },
    }
end

local function rand_spawn(map_def)
    local x = math.random(1, map_def.width)
    local y = math.random(1, map_def.height)
    return x, y
end

local function get_region_id(map_def, x, y)
    local region_count = math.max(1, tonumber(map_def.region_count) or 1)
    local side = math.max(1, math.floor(math.sqrt(region_count)))
    local cell_w = math.max(1, math.floor(map_def.width / side))
    local cell_h = math.max(1, math.floor(map_def.height / side))
    local col = math.max(0, math.min(side - 1, math.floor((x - 1) / cell_w)))
    local row = math.max(0, math.min(side - 1, math.floor((y - 1) / cell_h)))
    local region_id = row * side + col + 1
    if region_id > region_count then
        region_id = region_count
    end
    return region_id
end

local function get_region_side(map_def)
    local region_count = math.max(1, tonumber(map_def.region_count) or 1)
    return math.max(1, math.floor(math.sqrt(region_count))), region_count
end

local function is_adjacent_region(map_def, from_region_id, to_region_id)
    if from_region_id == to_region_id then
        return true
    end
    local side = get_region_side(map_def)
    local a = from_region_id - 1
    local b = to_region_id - 1
    if a < 0 or b < 0 then
        return false
    end
    local ar, ac = math.floor(a / side), a % side
    local br, bc = math.floor(b / side), b % side
    return math.abs(ar - br) + math.abs(ac - bc) == 1
end

local function ensure_map_monsters(map_id, map_def)
    local monsters = M.map_monsters[map_id]
    if monsters then
        return monsters
    end
    monsters = {}
    for i = 1, 8 do
        local x, y = rand_spawn(map_def)
        local uid = string.format("%d_%d", map_id, i)
        monsters[uid] = {
            uid = uid,
            map_id = map_id,
            x = x,
            y = y,
            region_id = get_region_id(map_def, x, y),
            alive = true,
            kind = "normal",
        }
    end
    M.map_monsters[map_id] = monsters
    return monsters
end

local function ensure_map_items(map_id, map_def)
    local items = M.map_items[map_id]
    if items then
        return items
    end
    items = {}
    for i = 1, 12 do
        local x, y = rand_spawn(map_def)
        local uid = string.format("%d_i_%d", map_id, i)
        items[uid] = {
            uid = uid,
            map_id = map_id,
            x = x,
            y = y,
            region_id = get_region_id(map_def, x, y),
            alive = true,
            item_id = 10001 + ((i - 1) % 3),
            count = 1,
        }
    end
    M.map_items[map_id] = items
    return items
end

local function ensure_public_monsters(map_id, map_def)
    local monsters = M.map_public_monsters[map_id]
    if monsters then
        return monsters
    end
    monsters = {}
    for i = 1, 4 do
        local x, y = rand_spawn(map_def)
        local uid = string.format("pub_%d_%d", map_id, i)
        monsters[uid] = {
            uid = uid,
            map_id = map_id,
            x = x,
            y = y,
            region_id = get_region_id(map_def, x, y),
            alive = true,
            kind = "public",
            visibility_layer = 2,
            owner_player_id = 0,
        }
    end
    M.map_public_monsters[map_id] = monsters
    return monsters
end

local function ensure_public_items(map_id, map_def)
    local items = M.map_public_items[map_id]
    if items then
        return items
    end
    items = {}
    for i = 1, 6 do
        local x, y = rand_spawn(map_def)
        local uid = string.format("pub_i_%d_%d", map_id, i)
        items[uid] = {
            uid = uid,
            map_id = map_id,
            x = x,
            y = y,
            region_id = get_region_id(map_def, x, y),
            alive = true,
            item_id = 10001 + ((i - 1) % 3),
            count = 1,
            visibility_layer = 2,
            owner_player_id = 0,
        }
    end
    M.map_public_items[map_id] = items
    return items
end

local function ensure_public_region_opened(map_id)
    local opened = M.public_region_opened[map_id]
    if opened then
        return opened
    end
    opened = {}
    M.public_region_opened[map_id] = opened
    return opened
end

local function ensure_player_private_monsters(player_id, map_id, map_def)
    local by_player = M.player_private_monsters[player_id]
    if not by_player then
        by_player = {}
        M.player_private_monsters[player_id] = by_player
    end
    local monsters = by_player[map_id]
    if monsters then
        return monsters
    end
    monsters = {}
    for i = 1, 8 do
        local x, y = rand_spawn(map_def)
        local uid = string.format("pri_%d_%d_%d", player_id, map_id, i)
        monsters[uid] = {
            uid = uid,
            map_id = map_id,
            x = x,
            y = y,
            region_id = get_region_id(map_def, x, y),
            alive = true,
            kind = "private",
            visibility_layer = 1,
            owner_player_id = player_id,
        }
    end
    by_player[map_id] = monsters
    return monsters
end

local function ensure_player_private_items(player_id, map_id, map_def)
    local by_player = M.player_private_items[player_id]
    if not by_player then
        by_player = {}
        M.player_private_items[player_id] = by_player
    end
    local items = by_player[map_id]
    if items then
        return items
    end
    items = {}
    for i = 1, 12 do
        local x, y = rand_spawn(map_def)
        local uid = string.format("pri_i_%d_%d_%d", player_id, map_id, i)
        items[uid] = {
            uid = uid,
            map_id = map_id,
            x = x,
            y = y,
            region_id = get_region_id(map_def, x, y),
            alive = true,
            item_id = 10001 + ((i - 1) % 3),
            count = 1,
            visibility_layer = 1,
            owner_player_id = player_id,
        }
    end
    by_player[map_id] = items
    return items
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

local function get_players_in_map(map_id)
    local players = {}
    for player_id, st in pairs(M.player_state) do
        if st.current_map_id == map_id and st.current_scene_id > 0 then
            players[#players + 1] = player_id
        end
    end
    return players
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

local function acquire_lock(lock_key)
    local now = skynet.now()
    local expire_at = M.entity_locks[lock_key]
    if expire_at and expire_at > now then
        return false
    end
    -- 2秒保护窗口，防并发重复交互
    M.entity_locks[lock_key] = now + 200
    return true
end

local function release_lock(lock_key)
    M.entity_locks[lock_key] = nil
end

local function cleanup_expired_locks()
    local now = skynet.now()
    for lock_key, expire_at in pairs(M.entity_locks) do
        if (tonumber(expire_at) or 0) <= now then
            M.entity_locks[lock_key] = nil
        end
    end
end

local function cleanup_stale_battles()
    local now = skynet.now()
    for player_id, battle in pairs(M.player_battles) do
        local deadline = tonumber(battle and battle.deadline_tick) or 0
        if deadline > 0 and deadline <= now then
            if battle.lock_key then
                release_lock(battle.lock_key)
            end
            M.player_battles[player_id] = nil
            log.warning("map battle timeout cleanup, player_id=%s, monster_uid=%s", tostring(player_id), tostring(battle.monster_uid))
        end
    end
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

        -- 1) 内容完全一致直接去重
        if same_content then
            return
        end

        -- 2) 同阶段同区域短时间抖动做轻节流（300ms）
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

local function summarize_progress(st, map_def)
    local total = math.max(1, tonumber(map_def.region_count) or 1)
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

local function can_interact_entity(st, entity)
    if not st or not entity then
        return false, "invalid state or entity"
    end
    local owner_id = entity.owner_player_id or 0
    if owner_id ~= 0 and owner_id ~= st.player_id then
        return false, "entity not owned by player"
    end
    local region_id = entity.region_id or 0
    if not is_region_visible(st, region_id) then
        return false, "entity not visible"
    end
    if owner_id == 0 then
        local opened_regions = ensure_public_region_opened(st.current_map_id)
        if not opened_regions[region_id] then
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

local function build_alive_monsters(map_id, st)
    local monsters = {}
    if not st then
        local opened_regions = ensure_public_region_opened(map_id)
        for uid, m in pairs(M.map_public_monsters[map_id] or {}) do
            local rid = m.region_id or 0
            if m.alive and opened_regions[rid] then
                monsters[#monsters + 1] = {
                    uid = uid,
                    x = m.x,
                    y = m.y,
                    kind = m.kind,
                    region_id = rid,
                    visibility_layer = m.visibility_layer or 2,
                    owner_player_id = m.owner_player_id or 0,
                }
            end
        end
        return monsters
    end
    local private_monsters = ((M.player_private_monsters[st.player_id] or {})[map_id]) or {}
    for uid, m in pairs(private_monsters) do
        local region_id = m.region_id or 0
        local p = st.region_progress[region_id]
        local region_cleared = p and p.cleared or false
        if m.alive and (region_id == st.current_region_id) and (not region_cleared) then
            monsters[#monsters + 1] = {
                uid = uid,
                x = m.x,
                y = m.y,
                kind = m.kind,
                region_id = region_id,
                visibility_layer = 1,
                owner_player_id = st.player_id,
            }
        end
    end
    local opened_regions = ensure_public_region_opened(map_id)
    for uid, m in pairs(M.map_public_monsters[map_id] or {}) do
        local rid = m.region_id or 0
        if m.alive and opened_regions[rid] and ((not st) or is_region_visible(st, rid)) then
            monsters[#monsters + 1] = {
                uid = uid,
                x = m.x,
                y = m.y,
                kind = m.kind,
                region_id = rid,
                visibility_layer = 2,
                owner_player_id = 0,
            }
        end
    end
    return monsters
end

local function build_alive_items(map_id, st)
    local items = {}
    if not st then
        local opened_regions = ensure_public_region_opened(map_id)
        for uid, it in pairs(M.map_public_items[map_id] or {}) do
            local rid = it.region_id or 0
            if it.alive and opened_regions[rid] then
                items[#items + 1] = {
                    uid = uid,
                    x = it.x,
                    y = it.y,
                    item_id = it.item_id,
                    count = it.count,
                    region_id = rid,
                    visibility_layer = it.visibility_layer or 2,
                    owner_player_id = it.owner_player_id or 0,
                }
            end
        end
        return items
    end
    local private_items = ((M.player_private_items[st.player_id] or {})[map_id]) or {}
    for uid, it in pairs(private_items) do
        local region_id = it.region_id or 0
        local p = st.region_progress[region_id]
        local region_cleared = p and p.cleared or false
        if it.alive and (region_id == st.current_region_id) and (not region_cleared) then
            items[#items + 1] = {
                uid = uid,
                x = it.x,
                y = it.y,
                item_id = it.item_id,
                count = it.count,
                region_id = region_id,
                visibility_layer = 1,
                owner_player_id = st.player_id,
            }
        end
    end
    local opened_regions = ensure_public_region_opened(map_id)
    for uid, it in pairs(M.map_public_items[map_id] or {}) do
        local rid = it.region_id or 0
        if it.alive and opened_regions[rid] and ((not st) or is_region_visible(st, rid)) then
            items[#items + 1] = {
                uid = uid,
                x = it.x,
                y = it.y,
                item_id = it.item_id,
                count = it.count,
                region_id = rid,
                visibility_layer = 2,
                owner_player_id = 0,
            }
        end
    end
    return items
end

local function notify_visible_sync(player_id, map_id, st)
    protocol_handler.send_to_player(player_id, "map_visible_sync_notify", {
        map_id = map_id or 0,
        region_id = st.current_region_id or 0,
        monsters = build_alive_monsters(map_id, st),
        items = build_alive_items(map_id, st),
    })
end

local function notify_visible_sync_to_players(player_ids, map_id)
    for _, player_id in ipairs(player_ids or {}) do
        local st = M.player_state[player_id]
        if st and st.current_map_id == map_id then
            notify_visible_sync(player_id, map_id, st)
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

local function recalc_region_left(map_id, st, region_id)
    local monster_left = 0
    local private_monsters = ((M.player_private_monsters[st.player_id] or {})[map_id]) or {}
    for _, m in pairs(private_monsters) do
        if m.alive and m.region_id == region_id then
            monster_left = monster_left + 1
        end
    end
    local item_left = 0
    local private_items = ((M.player_private_items[st.player_id] or {})[map_id]) or {}
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

local function maybe_clear_region(map_id, st, region_id, player_id)
    local was_cleared, now_cleared = recalc_region_left(map_id, st, region_id)
    if (not was_cleared) and now_cleared then
        notify_region_cleared(map_id, region_id, player_id, "private")
        notify_flow(player_id, map_id, "private_region_cleared", region_id)
        notify_flow(player_id, map_id, "region_cleared", region_id)
        notify_visible_sync(player_id, map_id, st)

        local opened_regions = ensure_public_region_opened(map_id)
        if not opened_regions[region_id] then
            opened_regions[region_id] = true
            notify_region_cleared(map_id, region_id, player_id, "public")
            local visible_players = get_players_visible_region(map_id, region_id)
            for _, viewer_id in ipairs(visible_players) do
                local vst = M.player_state[viewer_id]
                if vst then
                    local def = M.map_defs[map_id] or { region_count = 1 }
                    local explored_count, total_region_count, fog_percent = summarize_progress(vst, def)
                    notify_flow(viewer_id, map_id, "public_region_opened", region_id, {
                        explored_region_count = explored_count,
                        total_region_count = total_region_count,
                        fog_percent = fog_percent,
                        key_count = vst.key_count or 0,
                    })
                end
            end
            notify_visible_sync_to_players(visible_players, map_id)
        end

        local all_cleared = true
        local total = math.max(1, tonumber((M.map_defs[map_id] and M.map_defs[map_id].region_count) or 1))
        for rid = 1, total do
            local p = st.region_progress[rid]
            if not (p and p.cleared) then
                all_cleared = false
                break
            end
        end
        if all_cleared then
            notify_flow(player_id, map_id, "map_completed", region_id)
        end
    end
end

function M.init()
    if M._inited then
        return true
    end
    M._inited = true
    if next(M.map_defs) == nil then
        M.map_defs = make_default_maps()
    end
    log.info("Map service initialized, map_count=%d", (function()
        local n = 0
        for _ in pairs(M.map_defs) do
            n = n + 1
        end
        return n
    end)())
    return true
end

function M.get_map_list(_player_id)
    local list = {}
    for map_id, def in pairs(M.map_defs) do
        list[#list + 1] = {
            map_id = map_id,
            name = def.name,
            region_count = def.region_count,
        }
    end
    table.sort(list, function(a, b)
        return a.map_id < b.map_id
    end)
    return list
end

function M.enter_map(player_id, player_name, map_id)
    local def = M.map_defs[map_id]
    if not def then
        return false, "map not found"
    end

    local sceneS = skynet.localname(".scene")
    if not sceneS then
        return false, "scene service unavailable"
    end

    local st = get_or_init_player_state(player_id)
    st.player_id = player_id
    if st.current_scene_id and st.current_scene_id > 0 then
        pcall(skynet.call, sceneS, "lua", "leave_scene", st.current_scene_id, player_id)
    end

    local ok, err = skynet.call(sceneS, "lua", "ensure_scene", map_id, {
        width = def.width,
        height = def.height,
        grid_size = def.grid_size,
    })
    if not ok then
        return false, err or "ensure scene failed"
    end

    local x, y = rand_spawn(def)
    local enter_ok, enter_err = skynet.call(sceneS, "lua", "enter_scene", map_id, {
        id = player_id,
        type = "player",
        x = x,
        y = y,
        properties = {
            player_id = player_id,
            player_name = player_name or ("Player_" .. tostring(player_id)),
            map_id = map_id,
        },
    })
    if not enter_ok then
        return false, enter_err or "enter scene failed"
    end

    st.current_map_id = map_id
    st.current_scene_id = map_id
    st.x = x
    st.y = y
    st.region_progress = {}
    local region_id = get_region_id(def, x, y)
    st.current_region_id = region_id
    st.region_progress[region_id] = st.region_progress[region_id] or {
        unlocked = true,
        explored = true,
        cleared = false,
    }
    ensure_map_monsters(map_id, def)
    ensure_map_items(map_id, def)
    ensure_public_monsters(map_id, def)
    ensure_public_items(map_id, def)
    ensure_player_private_monsters(player_id, map_id, def)
    ensure_player_private_items(player_id, map_id, def)
    local explored_count, total_region_count, fog_percent = summarize_progress(st, def)
    for rid, _ in pairs(st.region_progress) do
        recalc_region_left(map_id, st, rid)
    end
    local monsters = build_alive_monsters(map_id, st)
    local items = build_alive_items(map_id, st)
    notify_flow(player_id, map_id, "entered_map", region_id, {
        explored_region_count = explored_count,
        total_region_count = total_region_count,
        fog_percent = fog_percent,
        key_count = st.key_count or 0,
    })

    return true, {
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
    }
end

function M.move(player_id, x, y)
    local st = get_or_init_player_state(player_id)
    if not st.current_scene_id or st.current_scene_id <= 0 then
        return false, "player not in map"
    end
    local sceneS = skynet.localname(".scene")
    if not sceneS then
        return false, "scene service unavailable"
    end
    local def = M.map_defs[st.current_map_id]
    local old_region_id = st.current_region_id
    local region_id = def and get_region_id(def, x, y) or old_region_id
    if def and old_region_id ~= 0 and region_id ~= old_region_id then
        if not is_adjacent_region(def, old_region_id, region_id) then
            return false, "只能前往相邻区域"
        end
        local target_progress = ensure_region_progress(st, region_id)
        if not target_progress.unlocked then
            return false, "目标区域未解锁"
        end
    end
    local ok, err = skynet.call(sceneS, "lua", "move_entity", st.current_scene_id, player_id, x, y)
    if not ok then
        return false, err or "move failed"
    end
    st.x = x
    st.y = y
    st.current_region_id = region_id
    if def and region_id > 0 then
        local p = st.region_progress[region_id]
        if not p then
            st.region_progress[region_id] = { unlocked = true, explored = true, cleared = false, monster_left = 0, item_left = 0 }
        elseif not p.explored then
            p.explored = true
        end
        recalc_region_left(st.current_map_id, st, region_id)
    end
    local explored_count, total_region_count, fog_percent = summarize_progress(st, def or { region_count = 1 })
    if old_region_id ~= region_id then
        protocol_handler.send_to_player(player_id, "map_progress_notify", {
            map_id = st.current_map_id,
            region_id = region_id,
            explored_region_count = explored_count,
            total_region_count = total_region_count,
            fog_percent = fog_percent,
        })
        notify_visible_sync(player_id, st.current_map_id, st)
    end
    return true, {
        map_id = st.current_map_id,
        region_id = region_id,
        x = x,
        y = y,
        explored_region_count = explored_count,
        total_region_count = total_region_count,
        fog_percent = fog_percent,
        key_count = st.key_count or 0,
    }
end

function M.interact_monster(player_id, monster_uid)
    cleanup_expired_locks()
    cleanup_stale_battles()
    local st = get_or_init_player_state(player_id)
    if not st.current_map_id or st.current_map_id <= 0 then
        return false, "player not in map"
    end

    local uid = tostring(monster_uid or "")
    if uid == "" then
        return false, "monster_uid is required"
    end
    if M.player_battles[player_id] then
        return false, "battle already in progress"
    end
    local private_monsters = ((M.player_private_monsters[player_id] or {})[st.current_map_id]) or {}
    local monsters = M.map_public_monsters[st.current_map_id] or {}
    local monster = private_monsters[uid] or monsters[uid]
    if not monster then
        return false, "monster not found"
    end
    local can_interact, why = can_interact_entity(st, monster)
    if not can_interact then
        return false, why
    end
    if not monster.alive then
        return false, "monster already defeated"
    end
    local lock_key = "monster:" .. tostring(st.current_map_id) .. ":" .. uid
    if not acquire_lock(lock_key) then
        return false, "monster is busy"
    end

    local instanceS = skynet.localname(".instance")
    if not instanceS then
        release_lock(lock_key)
        return false, "instance service unavailable"
    end

    local ok, result_or_err = skynet.call(instanceS, "lua", "play_start_direct", player_id, "single", {
        instance_type_name = "single",
        inst_no = 1001,
        ready_mode = "auto",
        result_source = "client",
        mode_type = "survival",
        mode_config = {
            target_seconds = 180,
        },
        join_data = {
            source = "map_monster",
            map_id = st.current_map_id,
            monster_uid = uid,
        },
    })
    if not ok then
        release_lock(lock_key)
        return false, result_or_err or "start monster instance failed"
    end

    M.player_battles[player_id] = {
        map_id = st.current_map_id,
        monster_uid = uid,
        lock_key = lock_key,
        inst_id = result_or_err.inst_id,
        start_tick = skynet.now(),
        deadline_tick = skynet.now() + BATTLE_TIMEOUT_TICK,
    }

    return true, {
        map_id = st.current_map_id,
        monster_uid = uid,
        battle_type = "monster_instance",
        inst_id = result_or_err.inst_id or "",
        scene_id = result_or_err.scene_id or 0,
        result = "accepted",
    }
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
        if battle.lock_key then
            release_lock(battle.lock_key)
        end
        M.player_battles[player_id] = nil
        return false, "monster uid mismatch"
    end

    local private_monsters = ((M.player_private_monsters[player_id] or {})[battle.map_id]) or {}
    local monsters = M.map_public_monsters[battle.map_id] or {}
    local monster = private_monsters[uid] or monsters[uid]
    if not monster then
        if battle.lock_key then
            release_lock(battle.lock_key)
        end
        M.player_battles[player_id] = nil
        return false, "monster not found"
    end

    if win then
        monster.alive = false
        notify_monster_removed(battle.map_id, monster.region_id or 0, uid, monster.x, monster.y, player_id)
        maybe_clear_region(battle.map_id, st, monster.region_id or 0, player_id)
    end
    if battle.lock_key then
        release_lock(battle.lock_key)
    end
    M.player_battles[player_id] = nil

    return true, {
        map_id = battle.map_id or st.current_map_id,
        monster_uid = uid,
        win = win and true or false,
        removed = win and true or false,
    }
end

function M.pick_item(player_id, item_uid)
    cleanup_expired_locks()
    local st = get_or_init_player_state(player_id)
    if not st.current_map_id or st.current_map_id <= 0 then
        return false, "player not in map"
    end
    local uid = tostring(item_uid or "")
    if uid == "" then
        return false, "item_uid is required"
    end
    local private_items = ((M.player_private_items[player_id] or {})[st.current_map_id]) or {}
    local items = M.map_public_items[st.current_map_id] or {}
    local item = private_items[uid] or items[uid]
    if not item then
        return false, "item not found"
    end
    local can_interact, why = can_interact_entity(st, item)
    if not can_interact then
        return false, why
    end
    if not item.alive then
        return false, "item already picked"
    end
    local lock_key = "item:" .. tostring(st.current_map_id) .. ":" .. uid
    if not acquire_lock(lock_key) then
        return false, "item is busy"
    end
    item.alive = false
    if item.item_id == 10003 then
        st.key_count = (st.key_count or 0) + (item.count or 1)
    end
    notify_item_removed(st.current_map_id, item.region_id or 0, uid, item.x, item.y, player_id)
    maybe_clear_region(st.current_map_id, st, item.region_id or 0, player_id)
    release_lock(lock_key)
    return true, {
        map_id = st.current_map_id,
        item_uid = uid,
        item_id = item.item_id,
        count = item.count,
        key_count = st.key_count or 0,
        removed = true,
    }
end

function M.leave_map(player_id)
    local st = M.player_state[player_id]
    if not st then
        return true
    end
    if st.current_scene_id and st.current_scene_id > 0 then
        local sceneS = skynet.localname(".scene")
        if sceneS then
            pcall(skynet.call, sceneS, "lua", "leave_scene", st.current_scene_id, player_id)
        end
    end
    st.current_map_id = 0
    st.current_scene_id = 0
    st.current_region_id = 0
    local battle = M.player_battles[player_id]
    if battle and battle.lock_key then
        release_lock(battle.lock_key)
    end
    M.player_battles[player_id] = nil
    M.flow_notify_cache[player_id] = nil
    return true
end

function M.sync_player_view(player_id)
    cleanup_expired_locks()
    cleanup_stale_battles()
    local st = get_or_init_player_state(player_id)
    if not st.current_map_id or st.current_map_id <= 0 then
        return false, "player not in map"
    end
    notify_visible_sync(player_id, st.current_map_id, st)
    return true, M.get_state(player_id)
end

function M.get_state(player_id)
    local st = get_or_init_player_state(player_id)
    local def = M.map_defs[st.current_map_id]
    local explored_count, total_region_count, fog_percent = summarize_progress(st, def or { region_count = 1 })
    return {
        map_id = st.current_map_id or 0,
        scene_id = st.current_scene_id or 0,
        region_id = st.current_region_id or 0,
        x = st.x or 0,
        y = st.y or 0,
        explored_region_count = explored_count,
        total_region_count = total_region_count,
        fog_percent = fog_percent,
        key_count = st.key_count or 0,
        monsters = st.current_map_id > 0 and build_alive_monsters(st.current_map_id, st) or {},
        items = st.current_map_id > 0 and build_alive_items(st.current_map_id, st) or {},
    }
end

function M.unlock_region(player_id, region_id)
    local st = get_or_init_player_state(player_id)
    if not st.current_map_id or st.current_map_id <= 0 then
        return false, "player not in map"
    end
    local def = M.map_defs[st.current_map_id]
    local rid = tonumber(region_id) or 0
    if rid <= 0 then
        return false, "invalid region_id"
    end
    if not is_adjacent_region(def, st.current_region_id, rid) then
        return false, "只能解锁相邻区域"
    end
    local p = ensure_region_progress(st, rid)
    if p.unlocked then
        return true, {
            map_id = st.current_map_id,
            region_id = rid,
            key_count = st.key_count or 0,
        }
    end
    if (st.key_count or 0) <= 0 then
        return false, "钥匙不足"
    end
    st.key_count = st.key_count - 1
    p.unlocked = true
    notify_region_unlocked(player_id, st.current_map_id, rid, st.key_count)
    notify_flow(player_id, st.current_map_id, "region_unlocked", rid, { key_count = st.key_count })
    return true, {
        map_id = st.current_map_id,
        region_id = rid,
        key_count = st.key_count,
    }
end

return M
