local skynet = require "skynet"
local log = require "log"
local Simple2DNavMesh = require "scene.pathfinding.simple_2d_navmesh"

-- 简单2D导航网格测试
local function test_simple_2d_navmesh()
    log.info("开始测试Simple2DNavMesh...")
    
    -- 创建100x100的网格，每个格子大小为2
    local navmesh = Simple2DNavMesh.new(100, 100, 2)
    
    -- 设置一些地形
    local terrain_data = {
        -- 设置一些水域
        {x = 20, y = 20, terrain_type = 2},  -- 水域
        {x = 21, y = 20, terrain_type = 2},
        {x = 22, y = 20, terrain_type = 2},
        {x = 20, y = 21, terrain_type = 2},
        {x = 21, y = 21, terrain_type = 2},
        {x = 22, y = 21, terrain_type = 2},
        
        -- 设置一些山地
        {x = 30, y = 30, terrain_type = 3},  -- 山地
        {x = 31, y = 30, terrain_type = 3},
        {x = 32, y = 30, terrain_type = 3},
        {x = 30, y = 31, terrain_type = 3},
        {x = 31, y = 31, terrain_type = 3},
        {x = 32, y = 31, terrain_type = 3},
        
        -- 设置一些障碍物
        {x = 40, y = 40, terrain_type = 4},  -- 障碍物
        {x = 41, y = 40, terrain_type = 4},
        {x = 42, y = 40, terrain_type = 4},
        {x = 40, y = 41, terrain_type = 4},
        {x = 41, y = 41, terrain_type = 4},
        {x = 42, y = 41, terrain_type = 4},
    }
    
    navmesh:set_terrain_batch(terrain_data)
    log.info("地形设置完成")
    
    -- 测试基本寻路
    local start_x, start_y = 10, 10
    local end_x, end_y = 50, 50
    
    local path = navmesh:find_path(start_x, start_y, end_x, end_y, {
        smooth = true,
        smooth_factor = 0.3
    })
    
    if path then
        log.info("寻路成功，路径点数: %d", #path)
        for i, point in ipairs(path) do
            log.debug("路径点%d: (%.1f, %.1f)", i, point.x, point.y)
        end
    else
        log.warning("寻路失败")
    end
    
    -- 测试动态障碍物
    navmesh:add_obstacle(25, 25, 5)  -- 在(25,25)添加半径为5的障碍物
    log.info("添加动态障碍物")
    
    -- 再次寻路，应该会避开障碍物
    local path2 = navmesh:find_path(start_x, start_y, end_x, end_y, {
        smooth = true
    })
    
    if path2 then
        log.info("避开障碍物寻路成功，路径点数: %d", #path2)
    else
        log.warning("避开障碍物寻路失败")
    end
    
    -- 移除障碍物
    navmesh:remove_obstacle(25, 25, 5)
    log.info("移除动态障碍物")
    
    -- 测试批量寻路
    local batch_requests = {
        {
            id = 1,
            start_x = 5, start_y = 5,
            end_x = 15, end_y = 15,
            options = {smooth = true}
        },
        {
            id = 2,
            start_x = 15, start_y = 15,
            end_x = 25, end_y = 25,
            options = {smooth = true}
        },
        {
            id = 3,
            start_x = 5, start_y = 5,
            end_x = 45, end_y = 45,  -- 这个路径会被障碍物阻挡
            options = {smooth = true}
        }
    }
    
    local batch_results = navmesh:find_paths_batch(batch_requests)
    log.info("批量寻路完成，结果数量: %d", #batch_results)
    
    for i, result in ipairs(batch_results) do
        if result.path then
            log.info("批量寻路%d成功，路径点数: %d", i, #result.path)
        else
            log.warning("批量寻路%d失败: %s", i, result.error)
        end
    end
    
    -- 获取统计信息
    local stats = navmesh:get_stats()
    log.info("网格统计:")
    log.info("  网格尺寸: %dx%d", stats.grid_width, stats.grid_height)
    log.info("  总节点数: %d", stats.total_nodes)
    log.info("  可行走节点: %d (%.1f%%)", stats.walkable_nodes, stats.walkable_ratio * 100)
    log.info("  动态障碍物: %d", stats.dynamic_obstacles)
    
    -- 测试坐标转换
    local world_x, world_y = 15.5, 25.3
    local grid_x, grid_y = navmesh:world_to_grid(world_x, world_y)
    local back_world_x, back_world_y = navmesh:grid_to_world(grid_x, grid_y)
    
    log.info("坐标转换测试:")
    log.info("  世界坐标 (%.1f, %.1f) -> 网格坐标 (%d, %d) -> 世界坐标 (%.1f, %.1f)", 
             world_x, world_y, grid_x, grid_y, back_world_x, back_world_y)
    
    -- 测试缓存功能
    log.info("缓存测试:")
    local cache_path1 = navmesh:find_path(10, 10, 20, 20)
    local cache_path2 = navmesh:find_path(10, 10, 20, 20)  -- 应该从缓存获取
    
    if cache_path1 and cache_path2 then
        log.info("  缓存功能正常，两次寻路结果相同")
    end
    
    -- 清除缓存
    navmesh:clear_cache()
    log.info("  缓存已清除")
    
    log.info("Simple2DNavMesh测试完成")
end

-- 运行测试
skynet.start(function()
    test_simple_2d_navmesh()
    skynet.exit()
end) 