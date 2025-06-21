local skynet = require "skynet"
local recast = require "recast"
local log = require "log"

-- 测试RecastNavigation功能
local function test_recast_navigation()
    log.info("开始测试RecastNavigation功能")
    
    -- 初始化RecastNavigation
    if not recast.init() then
        log.error("RecastNavigation初始化失败")
        return false
    end
    log.info("RecastNavigation初始化成功")
    
    -- 创建测试地形数据
    local width = 20
    local height = 20
    local terrain_data = {}
    
    -- 生成简单的地形数据
    for z = 1, height do
        terrain_data[z] = {}
        for x = 1, width do
            -- 创建一些障碍物
            if (x == 5 and z >= 5 and z <= 15) or 
               (x == 15 and z >= 5 and z <= 15) or
               (z == 5 and x >= 5 and x <= 15) or
               (z == 15 and x >= 5 and x <= 15) then
                terrain_data[z][x] = 4  -- OBSTACLE
            else
                terrain_data[z][x] = 1  -- PLAIN
            end
        end
    end
    
    -- 创建导航网格
    local navmesh_config = {
        width = width,
        height = height,
        terrain_data = terrain_data,
        cell_size = 1.0,
        cell_height = 0.5,
        walkable_slope_angle = 45.0,
    }
    
    local navmesh_id = recast.create_navmesh(navmesh_config)
    if not navmesh_id then
        log.error("创建导航网格失败")
        return false
    end
    log.info("创建导航网格成功，ID: %d", navmesh_id)
    
    -- 测试寻路 - 使用在多边形范围内的坐标
    local start_x, start_y, start_z = 9.0, 2.0, 9.0  -- 在多边形内部
    local end_x, end_y, end_z = 10.0, 2.0, 10.0      -- 在多边形内部
    
    local path = recast.find_path(navmesh_id, start_x, start_y, start_z, end_x, end_y, end_z)
    if not path then
        log.error("寻路失败")
        return false
    end
    
    log.info("寻路成功，路径点数: %d", #path)
    for i, point in ipairs(path) do
        log.info("路径点 %d: (%.2f, %.2f, %.2f)", i, point[1], point[2], point[3])
    end
    
    -- 测试动态障碍物
    local obstacle_id = recast.add_obstacle(navmesh_id, 10.0, 0.0, 10.0, 2.0, 3.0)
    if obstacle_id then
        log.info("添加动态障碍物成功，ID: %d", obstacle_id)
        
        -- 再次寻路，应该避开障碍物
        local new_path = recast.find_path(navmesh_id, start_x, start_y, start_z, end_x, end_y, end_z)
        if new_path then
            log.info("避开障碍物寻路成功，路径点数: %d", #new_path)
        else
            log.warn("避开障碍物寻路失败")
        end
        
        -- 移除障碍物
        if recast.remove_obstacle(navmesh_id, obstacle_id) then
            log.info("移除动态障碍物成功")
        else
            log.error("移除动态障碍物失败")
        end
    else
        log.error("添加动态障碍物失败")
    end
    
    -- 清理资源
    if recast.destroy_navmesh(navmesh_id) then
        log.info("销毁导航网格成功")
    else
        log.error("销毁导航网格失败")
    end
    
    log.info("RecastNavigation测试完成")
    return true
end

-- 测试导航网格文件保存和加载功能
local function test_navmesh_file_operations()
    log.info("开始测试导航网格文件操作功能")
    
    -- 创建一个小型测试导航网格
    local testConfig = {
        width = 10,
        height = 10,
        cell_size = 1.0,
        cell_height = 0.5,
        walkable_slope_angle = 45.0,
        terrain_data = {}
    }
    
    -- 创建简单的测试地形数据
    for z = 1, 10 do
        testConfig.terrain_data[z] = {}
        for x = 1, 10 do
            -- 大部分是平地，边缘是障碍物
            if x == 1 or x == 10 or z == 1 or z == 10 then
                testConfig.terrain_data[z][x] = 4  -- OBSTACLE
            else
                testConfig.terrain_data[z][x] = 1  -- PLAIN
            end
        end
    end
    
    log.info("创建测试导航网格...")
    local navMeshId = recast.create_navmesh(testConfig)
    if not navMeshId then
        log.error("创建导航网格失败")
        return false
    end
    
    log.info("导航网格创建成功，ID: %d", navMeshId)
    
    -- 保存导航网格到文件
    log.info("保存导航网格到文件...")
    local success = recast.save_navmesh_to_file(navMeshId, "test_navmesh.bin")
    if success then
        log.info("导航网格保存成功")
    else
        log.error("导航网格保存失败")
        return false
    end
    
    -- 销毁原始导航网格
    recast.destroy_navmesh(navMeshId)
    log.info("原始导航网格已销毁")
    
    -- 从文件重新加载导航网格
    log.info("从文件加载导航网格...")
    local newNavMeshId = recast.create_navmesh_from_file("test_navmesh.bin")
    if newNavMeshId then
        log.info("从文件加载导航网格成功，ID: %d", newNavMeshId)
        
        -- 测试寻路功能
        log.info("测试寻路功能...")
        local path = recast.find_path(newNavMeshId, 2, 0, 2, 8, 0, 8)
        if path then
            log.info("寻路成功，路径点数: %d", #path)
            for i = 1, #path do
                log.info("路径点 %d: (%.2f, %.2f, %.2f)", 
                        i, path[i][1], path[i][2], path[i][3])
            end
        else
            log.error("寻路失败")
        end
        
        -- 清理
        recast.destroy_navmesh(newNavMeshId)
        log.info("测试完成，导航网格已清理")
    else
        log.error("从文件加载导航网格失败")
        return false
    end
    
    log.info("导航网格文件操作测试完成")
    return true
end

skynet.start(function()
    -- 运行基础功能测试
    if test_recast_navigation() then
        log.info("基础功能测试通过")
    else
        log.error("基础功能测试失败")
    end
    
    -- 运行文件操作测试
    if test_navmesh_file_operations() then
        log.info("文件操作测试通过")
    else
        log.error("文件操作测试失败")
    end
    
    log.info("所有测试完成")
end)