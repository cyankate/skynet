local log = require "log"
local service_ctx = require "runtime.service_ctx"
local shard = require "map.shard"
local MapPath = require "map.pathfinding"

local M = service_ctx.get("map.pathfinding_service", {})

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
