local log = require "log"
local service_ctx = require "runtime.service_ctx"
local recast = require "scene.pathfinding.recast"

local M = service_ctx.get("scene.pathfinding_service", {})

function M.create_navmesh_from_heightmap(heightmap, config)
    return recast.create_navmesh_from_heightmap(heightmap, config)
end

function M.create_navmesh_from_triangles(triangles, config)
    return recast.create_navmesh_from_triangles(triangles, config)
end

function M.find_path(navMeshId, start_pos, end_pos, options)
    log.info(" >>>>>>>>>>>>>>>>>>>>>> find_path %s %s %s %s", navMeshId, start_pos, end_pos, options)
    return recast.find_path(navMeshId, start_pos, end_pos, options)
end

function M.find_paths_batch(requests)
    return recast.find_paths_batch(requests)
end

function M.add_obstacle(navMeshId, obstacle_data)
    return recast.add_obstacle(navMeshId, obstacle_data)
end

function M.remove_obstacle(navMeshId, obstacleId)
    return recast.remove_obstacle(navMeshId, obstacleId)
end

function M.get_navmesh_info(navMeshId)
    return recast.get_navmesh_info(navMeshId)
end

function M.destroy_navmesh(navMeshId)
    return recast.destroy_navmesh(navMeshId)
end

function M.cleanup()
    recast.cleanup()
end

function M.get_cache_stats()
    return {
        navmesh_count = 0,
        path_cache_count = 0,
        memory_usage = 0,
    }
end

function M.warmup_cache(navMeshId, common_paths)
    local warmed_count = 0
    for _, path_info in ipairs(common_paths) do
        local path = recast.find_path(navMeshId, path_info.start_pos, path_info.end_pos, path_info.options)
        if path then
            warmed_count = warmed_count + 1
        end
    end
    return warmed_count
end

function M.init()
    if M._inited then
        return true
    end

    local result = recast.init()
    if not result then
        log.error("RecastNavigation初始化失败")
        return false
    end

    M._inited = true
    log.info("RecastNavigation初始化成功")
    return true
end

return M
