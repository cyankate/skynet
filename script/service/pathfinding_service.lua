local log = require "log"
local service_ctx = require "runtime.service_ctx"
local shard = require "map.shard"
local MapPath = require "map.pathfinding"

local M = service_ctx.get("map.pathfinding_service", {})
M.blockers = M.blockers or {} -- uid => { id, x, y, radius }

local function get_map(map_id)
    if not M.map then
        return nil, "pathfinding not ready"
    end
    map_id = tonumber(map_id)
    if map_id and map_id ~= 0 and map_id ~= M.map.map_id then
        return nil, "unknown map"
    end
    return M.map
end

function M.find_path(map_id, sx, sy, ex, ey, keep_end)
    local map, err = get_map(map_id)
    if not map then
        return false, err
    end
    local path, path_err = map:find_path(sx, sy, ex, ey, keep_end)
    if not path then
        return false, path_err
    end
    return true, path
end

function M.is_walkable(map_id, x, y)
    local map, err = get_map(map_id)
    if not map then
        return false, err
    end
    return true, map:is_walkable(x, y)
end

function M.add_obstacle(map_id, x, y, radius)
    local map, err = get_map(map_id)
    if not map then
        return false, err
    end
    return true, map:add_obstacle(x, y, radius)
end

function M.remove_obstacle(map_id, obstacle_id)
    local map, err = get_map(map_id)
    if not map then
        return false, err
    end
    return map:remove_obstacle(obstacle_id)
end

function M.set_blocker(map_id, key, x, y, radius)
    local map, err = get_map(map_id)
    if not map then
        return false, err
    end
    key = tostring(key or "")
    if key == "" then
        return false, "invalid blocker key"
    end
    local prev = M.blockers[key]
    if prev and prev.id then
        map:remove_obstacle(prev.id)
    end
    radius = tonumber(radius) or MapPath.CITY_BLOCK_RADIUS
    local id = map:add_obstacle(x, y, radius)
    M.blockers[key] = {
        id = id,
        x = tonumber(x) or 0,
        y = tonumber(y) or 0,
        radius = radius,
    }
    return true, id
end

function M.clear_blocker(map_id, key)
    local map, err = get_map(map_id)
    if not map then
        return false, err
    end
    key = tostring(key or "")
    local prev = M.blockers[key]
    if not prev then
        return true
    end
    if prev.id then
        map:remove_obstacle(prev.id)
    end
    M.blockers[key] = nil
    return true
end

local function too_close(x, y, spacing)
    local s2 = spacing * spacing
    for _, b in pairs(M.blockers) do
        local dx = x - (b.x or 0)
        local dy = y - (b.y or 0)
        if dx * dx + dy * dy < s2 then
            return true
        end
    end
    return false
end

function M.pick_city_spawn(map_id, shard_id)
    local map, err = get_map(map_id)
    if not map then
        return false, err
    end
    local def = map.def
    shard_id = tonumber(shard_id)
    if shard_id == nil then
        return false, "invalid shard"
    end
    local radius = MapPath.CITY_BLOCK_RADIUS
    local spacing = MapPath.CITY_SPACING
    local x0, y0, x1, y1 = shard.pixel_rect(shard_id, def)
    local pad = radius + MapPath.CELL_SIZE
    local ix0, iy0, ix1, iy1 = x0 + pad, y0 + pad, x1 - pad, y1 - pad
    if ix1 < ix0 or iy1 < iy0 then
        ix0, iy0, ix1, iy1 = x0, y0, x1, y1
    end

    local function try_at(px, py, check_space)
        px, py = map:clamp(px, py)
        if not shard.owns_pos(shard_id, px, py, def) then
            return nil
        end
        local sx, sy = map:snap_walkable(px, py)
        if not sx then
            return nil
        end
        if not shard.owns_pos(shard_id, sx, sy, def) then
            return nil
        end
        if check_space and too_close(sx, sy, spacing) then
            return nil
        end
        return sx, sy
    end

    local start = def.start or {}
    if start.x and start.y and shard.owns_pos(shard_id, start.x, start.y, def) then
        for _ = 1, 12 do
            local jx = start.x + math.random(-spacing, spacing)
            local jy = start.y + math.random(-spacing, spacing)
            local x, y = try_at(jx, jy, true)
            if x then
                return true, { x = x, y = y }
            end
        end
    end
    for _ = 1, MapPath.SPAWN_TRIES do
        local x, y = try_at(math.random(ix0, ix1), math.random(iy0, iy1), true)
        if x then
            return true, { x = x, y = y }
        end
    end
    for _ = 1, 16 do
        local x, y = try_at(math.random(ix0, ix1), math.random(iy0, iy1), false)
        if x then
            log.warning("city spawn spacing relaxed, shard_id=%s", tostring(shard_id))
            return true, { x = x, y = y }
        end
    end
    return false, "没有空地建城"
end

function M.set_terrain(map_id, x, y, terrain_type)
    local map, err = get_map(map_id)
    if not map then
        return false, err
    end
    map:set_terrain(x, y, terrain_type)
    return true
end

function M.get_stats(map_id)
    local map, err = get_map(map_id)
    if not map then
        return false, err
    end
    return true, map:get_stats()
end

function M.init()
    if M._inited and M.map then
        return true
    end
    local def = shard.default_def()
    M.map = MapPath.new(def)
    M._inited = true
    log.info("map pathfinding ready, map_id=%s size=%dx%d cell=%d",
        tostring(def.map_id), def.width, def.height, MapPath.CELL_SIZE)
    return true
end

return M
