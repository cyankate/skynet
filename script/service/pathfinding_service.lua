local log = require "log"
local service_ctx = require "runtime.service_ctx"
local shard = require "map.shard"
local WorldPath = require "map.pathfinding"

local M = service_ctx.get("map.pathfinding_service", {})

local function get_world(map_id)
    if not M.world then
        return nil, "pathfinding not ready"
    end
    map_id = tonumber(map_id)
    if map_id and map_id ~= 0 and map_id ~= M.world.map_id then
        return nil, "unknown map"
    end
    return M.world
end

function M.find_path(map_id, sx, sy, ex, ey, keep_end)
    local world, err = get_world(map_id)
    if not world then
        return false, err
    end
    local path, path_err = world:find_path(sx, sy, ex, ey, keep_end)
    if not path then
        return false, path_err
    end
    return true, path
end

function M.is_walkable(map_id, x, y)
    local world, err = get_world(map_id)
    if not world then
        return false, err
    end
    return true, world:is_walkable(x, y)
end

function M.add_obstacle(map_id, x, y, radius)
    local world, err = get_world(map_id)
    if not world then
        return false, err
    end
    return true, world:add_obstacle(x, y, radius)
end

function M.remove_obstacle(map_id, obstacle_id)
    local world, err = get_world(map_id)
    if not world then
        return false, err
    end
    return world:remove_obstacle(obstacle_id)
end

function M.set_terrain(map_id, x, y, terrain_type)
    local world, err = get_world(map_id)
    if not world then
        return false, err
    end
    world:set_terrain(x, y, terrain_type)
    return true
end

function M.get_stats(map_id)
    local world, err = get_world(map_id)
    if not world then
        return false, err
    end
    return true, world:get_stats()
end

function M.init()
    if M._inited and M.world then
        return true
    end
    local def = shard.world_def()
    M.world = WorldPath.new(def)
    M._inited = true
    log.info("map pathfinding ready, map_id=%s size=%dx%d cell=%d",
        tostring(def.map_id), def.width, def.height, WorldPath.CELL_SIZE)
    return true
end

return M
