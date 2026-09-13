-- 大世界行军：独立实体，坐标权威跟位置走，交战权威跟攻击者走。
local aoi_object = require "map.aoi_object"

local M = {}

M.SPEED = 30
M.ENGAGE_RANGE = 40
M.DISENGAGE_RANGE = 80
M.TICK_SEC = 0.1
M.DAMAGE = 4
M.MAX_HP = 100
M.MAX_PER_PLAYER = 3
M.NOTIFY_MOVE = 8

M.STATE_MARCHING = "marching"
M.STATE_CHASE = "chase"
M.STATE_BATTLE = "battle"

function M.dist2(x1, y1, x2, y2)
    local dx = (tonumber(x1) or 0) - (tonumber(x2) or 0)
    local dy = (tonumber(y1) or 0) - (tonumber(y2) or 0)
    return dx * dx + dy * dy
end

function M.in_range(x1, y1, x2, y2, range)
    range = tonumber(range) or 0
    return M.dist2(x1, y1, x2, y2) <= range * range
end

function M.clamp(def, x, y)
    local w = (def and def.width) or 2048
    local h = (def and def.height) or 2048
    x = tonumber(x) or 1
    y = tonumber(y) or 1
    if x < 1 then
        x = 1
    elseif x > w then
        x = w
    end
    if y < 1 then
        y = 1
    elseif y > h then
        y = h
    end
    return x, y
end

function M.step(x, y, tx, ty, speed, dt)
    x = tonumber(x) or 0
    y = tonumber(y) or 0
    tx = tonumber(tx) or x
    ty = tonumber(ty) or y
    local dx, dy = tx - x, ty - y
    local d = math.sqrt(dx * dx + dy * dy)
    local step = (tonumber(speed) or M.SPEED) * (tonumber(dt) or M.TICK_SEC)
    if d <= step or d < 0.001 then
        return tx, ty, true
    end
    local k = step / d
    return x + dx * k, y + dy * k, false
end

function M.new(opts)
    opts = opts or {}
    local x = tonumber(opts.x) or 1
    local y = tonumber(opts.y) or 1
    local uid = opts.uid or ""
    return {
        uid = uid,
        type = aoi_object.TYPE.MARCH,
        view_range = 0,
        is_ghost = false,
        owner_player_id = opts.owner_player_id or 0,
        x = x,
        y = y,
        scene_x = math.floor(x + 0.5),
        scene_y = math.floor(y + 0.5),
        waypoints = opts.waypoints or {},
        wp_index = opts.wp_index or 1,
        speed = opts.speed or M.SPEED,
        hp = opts.hp or M.MAX_HP,
        max_hp = opts.max_hp or M.MAX_HP,
        state = opts.state or M.STATE_MARCHING,
        target_uid = opts.target_uid,
        target_shard_id = opts.target_shard_id,
        last_path_tx = opts.last_path_tx,
        last_path_ty = opts.last_path_ty,
        battle_id = opts.battle_id,
        host_shard_id = opts.host_shard_id,
        role = opts.role,
        map_id = opts.map_id,
        shard_id = opts.shard_id,
        owner_shard_id = opts.owner_shard_id or opts.shard_id,
        alive = opts.alive ~= false,
        in_aoi = false,
        last_notify_x = x,
        last_notify_y = y,
    }
end

function M.bind_map(m, map_id, shard_id)
    if not m then
        return m
    end
    return aoi_object.ensure(m, {
        type = aoi_object.TYPE.MARCH,
        view_range = 0,
        is_ghost = false,
        map_id = map_id,
        owner_shard_id = shard_id,
        shard_id = shard_id,
    })
end

function M.set_path(m, path)
    m.waypoints = path or {}
    m.wp_index = 1
    if #m.waypoints == 0 then
        m.waypoints = { { x = m.x, y = m.y } }
    end
end

function M.current_dest(m)
    if not m then
        return 0, 0
    end
    local wp = m.waypoints and m.waypoints[m.wp_index or 1]
    if wp then
        return wp.x, wp.y
    end
    return m.x, m.y
end

function M.pack_visible(m, shard_id)
    return aoi_object.pack_visible(m, { shard_id = shard_id })
end

function M.from_ghost(obj)
    if not obj or obj.type ~= aoi_object.TYPE.MARCH then
        return nil
    end
    return {
        uid = obj.uid,
        x = obj.x,
        y = obj.y,
        hp = tonumber(obj.hp) or M.MAX_HP,
        max_hp = tonumber(obj.max_hp) or M.MAX_HP,
        owner_player_id = obj.owner_player_id or 0,
        shard_id = tonumber(obj.owner_shard_id),
        battle_id = obj.battle_id,
        state = obj.state,
    }
end

function M.export(m)
    if not m then
        return nil
    end
    return {
        uid = m.uid,
        owner_player_id = m.owner_player_id,
        x = m.x,
        y = m.y,
        waypoints = m.waypoints,
        wp_index = m.wp_index,
        last_path_tx = m.last_path_tx,
        last_path_ty = m.last_path_ty,
        speed = m.speed,
        hp = m.hp,
        max_hp = m.max_hp,
        state = m.state,
        target_uid = m.target_uid,
        target_shard_id = m.target_shard_id,
        battle_id = m.battle_id,
        host_shard_id = m.host_shard_id,
        role = m.role,
        shard_id = m.shard_id,
        alive = m.alive,
    }
end

function M.from_export(snap)
    return M.new(snap)
end

return M
