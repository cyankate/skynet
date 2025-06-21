local skynet = require "skynet"
local log = require "log"
local RecastAPI = require "scene.pathfinding.recast"
local ParallelPathfinder = require "scene.pathfinding.parallel_pathfinding"

local function test_parallel_pathfinding()
    log.info("开始测试并行寻路系统")
    
    -- 2. 创建测试高度图
    local heightmap = {
        width = 100,
        height = 100,
        data = {}
    }
    
    -- 生成测试地形
    for y = 0, heightmap.height - 1 do
        heightmap.data[y] = {}
        for x = 0, heightmap.width - 1 do
            local height = 0
            -- 创建一些障碍物
            if x > 20 and x < 30 and y > 20 and y < 30 then
                height = 50  -- 山地
            elseif x > 40 and x < 60 and y > 40 and y < 60 then
                height = -10 -- 水域
            elseif x > 70 and x < 80 and y > 70 and y < 80 then
                height = 100 -- 高障碍物
            end
            heightmap.data[y][x] = height
        end
    end
    
    -- 3. 创建导航网格
    local navmesh_id = RecastAPI.create_navmesh_from_heightmap(heightmap, {
        cell_size = 1.0,
        cell_height = 0.5,
        walkable_slope_angle = 45
    })
    
    if not navmesh_id then
        log.error("创建导航网格失败")
        return
    end
    log.info("创建导航网格成功，ID: %d", navmesh_id)
    
    -- 4. 创建并行寻路器
    local pathfinder = ParallelPathfinder.new(navmesh_id)
    log.info("并行寻路器创建成功")
    
    -- 5. 测试单次寻路
    log.info("测试单次寻路...")
    local path1 = pathfinder:find_path(10, 0, 10, 90, 0, 90)
    if path1 then
        log.info("单次寻路成功，路径点数: %d", #path1)
        for i, point in ipairs(path1) do
            if i <= 5 or i > #path1 - 5 then  -- 只显示前5个和后5个点
                log.info("路径点%d: (%.2f, %.2f, %.2f)", i, point[1], point[2], point[3])
            elseif i == 6 then
                log.info("... (省略中间点)")
            end
        end
    else
        log.error("单次寻路失败")
    end
    
    -- 6. 测试批量寻路
    log.info("测试批量寻路...")
    local requests = {
        {
            id = 1,
            start_x = 5, start_y = 0, start_z = 5,
            end_x = 95, end_y = 0, end_z = 95,
            options = {max_path_length = 128}
        },
        {
            id = 2,
            start_x = 15, start_y = 0, start_z = 15,
            end_x = 85, end_y = 0, end_z = 85,
            options = {max_path_length = 128}
        },
        {
            id = 3,
            start_x = 25, start_y = 0, start_z = 25,
            end_x = 75, end_y = 0, end_z = 75,
            options = {max_path_length = 128}
        }
    }
    
    local batch_results = pathfinder:find_paths_batch(requests)
    for i, result in ipairs(batch_results) do
        if result.path then
            log.info("批量寻路%d成功，路径点数: %d", i, #result.path)
        else
            log.error("批量寻路%d失败: %s", i, result.error)
        end
    end
    
    -- 7. 测试缓存功能
    log.info("测试缓存功能...")
    local cache_stats = pathfinder:get_cache_stats()
    log.info("缓存统计: 路径缓存=%d, 区域缓存=%d, 区域数量=%d", 
             cache_stats.path_cache_count, cache_stats.region_cache_count, cache_stats.region_count)
    
    -- 8. 测试同一路径的缓存命中
    local path2 = pathfinder:find_path(10, 0, 10, 90, 0, 90)
    if path2 then
        log.info("缓存测试成功，路径点数: %d", #path2)
    end
    
    -- 9. 测试不同区域的寻路
    log.info("测试跨区域寻路...")
    local cross_region_path = pathfinder:find_path(5, 0, 5, 95, 0, 95)
    if cross_region_path then
        log.info("跨区域寻路成功，路径点数: %d", #cross_region_path)
    else
        log.error("跨区域寻路失败")
    end
    
    -- 10. 测试无效坐标
    log.info("测试无效坐标...")
    local invalid_path = pathfinder:find_path(-10, 0, -10, 110, 0, 110)
    if not invalid_path then
        log.info("无效坐标测试通过，正确返回nil")
    else
        log.error("无效坐标测试失败，不应该找到路径")
    end
    
    -- 11. 清理资源
    log.info("清理资源...")
    pathfinder:clear_cache()
    RecastAPI.destroy_navmesh(navmesh_id)
    RecastAPI.cleanup()
    
    log.info("并行寻路系统测试完成")
end

-- 启动测试
skynet.start(function()
    test_parallel_pathfinding()
    skynet.exit()
end) 