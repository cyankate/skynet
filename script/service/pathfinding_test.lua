local skynet = require "skynet"
local log = require "log"

-- 路径查找服务测试
local function test_pathfinding_service()
    log.info("开始测试路径查找服务...")
    
    -- 创建测试高度图
    local heightmap = {
        width = 100,
        height = 100,
        data = {}
    }
    
    -- 生成简单的高度图数据
    for y = 0, heightmap.height - 1 do
        heightmap.data[y] = {}
        for x = 0, heightmap.width - 1 do
            -- 创建一个简单的平面地形
            heightmap.data[y][x] = 0
        end
    end
    
    -- 添加一些障碍物
    for x = 20, 30 do
        for y = 20, 30 do
            heightmap.data[y][x] = 10  -- 高障碍物
        end
    end

    local pathfinding_service = skynet.localname(".pathfinding")
    
    -- 创建导航网格
    local navmesh_id = skynet.call(pathfinding_service, "lua", "create_navmesh_from_heightmap", heightmap, {
        cell_size = 0.5,
        cell_height = 0.2,
        walkable_slope_angle = 45
    })
    
    if not navmesh_id then
        log.error("创建导航网格失败")
        return
    end
    log.info("创建导航网格成功, ID: %d", navmesh_id)
    
    -- 测试寻路
    local start_pos = {0, 0, 0}
    local end_pos = {50, 0, 50}
    
    local path = skynet.call(pathfinding_service, "lua", "find_path", navmesh_id, start_pos, end_pos, {
        max_path_length = 256
    })
    
    if path then
        log.info("寻路成功，路径点数: %d", #path)
        for i, point in ipairs(path) do
            log.debug("路径点%d: (%.2f, %.2f, %.2f)", i, point[1], point[2], point[3])
        end
    else
        log.warning("寻路失败")
    end
    
    -- 测试批量寻路
    local batch_requests = {
        {
            id = 1,
            navmesh_id = navmesh_id,
            start_pos = {0, 0, 0},
            end_pos = {25, 0, 25},
            options = {max_path_length = 128}
        },
        {
            id = 2,
            navmesh_id = navmesh_id,
            start_pos = {25, 0, 25},
            end_pos = {50, 0, 50},
            options = {max_path_length = 128}
        }
    }
    
    local batch_results = skynet.call(pathfinding_service, "lua", "find_paths_batch", batch_requests)
    log.info("批量寻路完成，结果数量: %d", #batch_results)
    
    for i, result in ipairs(batch_results) do
        if result.path then
            log.info("批量寻路%d成功，路径点数: %d", i, #result.path)
        else
            log.warning("批量寻路%d失败: %s", i, result.error or "未知错误")
        end
    end
    
    -- 测试动态障碍物
    local obstacle_data = {
        x = 15, y = 0, z = 15,
        radius = 2.0,
        height = 5.0
    }
    
    local obstacle_id = skynet.call(pathfinding_service, "lua", "add_obstacle", navmesh_id, obstacle_data)
    if obstacle_id then
        log.info("添加动态障碍物成功，ID: %d", obstacle_id)
        
        -- 再次寻路，应该会避开障碍物
        local new_path = skynet.call(pathfinding_service, "lua", "find_path", navmesh_id, start_pos, end_pos)
        if new_path then
            log.info("避开障碍物寻路成功，路径点数: %d", #new_path)
        end
        
        -- 移除障碍物
        local remove_result = skynet.call(pathfinding_service, "lua", "remove_obstacle", navmesh_id, obstacle_id)
        if remove_result then
            log.info("移除动态障碍物成功")
        end
    end
    
    -- 获取导航网格信息
    local navmesh_info = skynet.call(pathfinding_service, "lua", "get_navmesh_info", navmesh_id)
    if navmesh_info then
        log.info("导航网格信息: ID=%d, 配置=%s", navmesh_info.id, navmesh_info.config and "已配置" or "未配置")
    end
    
    -- 测试缓存预热
    local common_paths = {
        {start_pos = {0, 0, 0}, end_pos = {25, 0, 25}},
        {start_pos = {25, 0, 25}, end_pos = {50, 0, 50}},
        {start_pos = {0, 0, 0}, end_pos = {50, 0, 50}}
    }
    
    local warmed_count = skynet.call(pathfinding_service, "lua", "warmup_cache", navmesh_id, common_paths)
    log.info("缓存预热完成，预热路径数: %d", warmed_count)
    
    -- 获取缓存统计
    local cache_stats = skynet.call(pathfinding_service, "lua", "get_cache_stats")
    log.info("缓存统计: 导航网格=%d, 路径缓存=%d, 内存使用=%d", 
             cache_stats.navmesh_count, cache_stats.path_cache_count, cache_stats.memory_usage)
    
    -- 清理资源
    skynet.call(pathfinding_service, "lua", "cleanup")
    log.info("路径查找服务测试完成")
end

-- 运行测试
skynet.start(function()
    log.info(" >>>>>>>>>>>>>>>>>>>>>> pathfinding_test start")
    test_pathfinding_service()
    -- skynet.exit()
end) 