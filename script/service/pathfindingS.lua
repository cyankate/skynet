local skynet = require "skynet"
local recast = require "scene.pathfinding.recast"  -- 使用高级接口
local service_wrapper = require "utils.service_wrapper"

-- 从高度图创建导航网格
function CMD.create_navmesh_from_heightmap(heightmap, config)
    local navMeshId, error = recast.create_navmesh_from_heightmap(heightmap, config)
    return navMeshId, error
end

-- 从三角形网格创建导航网格
function CMD.create_navmesh_from_triangles(triangles, config)
    local navMeshId, error = recast.create_navmesh_from_triangles(triangles, config)
    return navMeshId, error
end

-- 寻路
function CMD.find_path(navMeshId, start_pos, end_pos, options)
    log.info(" >>>>>>>>>>>>>>>>>>>>>> find_path %s %s %s %s", navMeshId, start_pos, end_pos, options)
    local path, error = recast.find_path(navMeshId, start_pos, end_pos, options)
    return path, error
end

-- 批量寻路
function CMD.find_paths_batch(requests)
    local results = recast.find_paths_batch(requests)
    return results
end

-- 添加动态障碍物
function CMD.add_obstacle(navMeshId, obstacle_data)
    local obstacleId, error = recast.add_obstacle(navMeshId, obstacle_data)
    return obstacleId, error
end

-- 移除动态障碍物
function CMD.remove_obstacle(navMeshId, obstacleId)
    local success, error = recast.remove_obstacle(navMeshId, obstacleId)
    return success, error
end

-- 获取导航网格信息
function CMD.get_navmesh_info(navMeshId)
    local info, error = recast.get_navmesh_info(navMeshId)
    return info, error
end

-- 销毁导航网格
function CMD.destroy_navmesh(navMeshId)
    local success, error = recast.destroy_navmesh(navMeshId)
    return success, error
end

-- 清理所有资源
function CMD.cleanup()
    recast.cleanup()
end

-- 获取缓存统计信息
function CMD.get_cache_stats()
    -- 这里可以添加缓存统计功能
    local stats = {
        navmesh_count = 0,
        path_cache_count = 0,
        memory_usage = 0
    }
    return stats
end

-- 预热路径缓存
function CMD.warmup_cache(navMeshId, common_paths)
    -- 这里可以添加缓存预热功能
    local warmed_count = 0
    for _, path_info in ipairs(common_paths) do
        local path = recast.find_path(navMeshId, path_info.start_pos, path_info.end_pos, path_info.options)
        if path then
            warmed_count = warmed_count + 1
        end
    end
    return warmed_count
end

local function main()
    local result = recast.init()
    if not result then
        log.error("RecastNavigation初始化失败")
        return
    end
    log.info("RecastNavigation初始化成功")
end

service_wrapper.create_service(main, {
    name = "pathfinding",
})
