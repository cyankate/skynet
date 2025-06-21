local skynet = require "skynet"
local log = require "log"
local Simple2DNavMesh = require "scene.pathfinding.simple_2d_navmesh"

local function test_overlap_detection()
    log.info("开始重叠检测测试")
    
    local navmesh = Simple2DNavMesh.new(100, 100, 10)  -- 10x10网格，每个格子10x10
    
    -- 测试1：障碍物完全覆盖格子
    local result1 = navmesh:check_obstacle_grid_overlap(15, 15, 20, 1, 1)  -- 障碍物中心(15,15)，半径20，格子(1,1)
    log.info("测试1 - 障碍物完全覆盖格子: %s (期望: true)", tostring(result1))
    
    -- 测试2：障碍物部分覆盖格子
    local result2 = navmesh:check_obstacle_grid_overlap(25, 15, 10, 2, 1)  -- 障碍物中心(25,15)，半径10，格子(2,1)
    log.info("测试2 - 障碍物部分覆盖格子: %s (期望: true)", tostring(result2))
    
    -- 测试3：障碍物边缘接触格子
    local result3 = navmesh:check_obstacle_grid_overlap(35, 15, 5, 3, 1)  -- 障碍物中心(35,15)，半径5，格子(3,1)
    log.info("测试3 - 障碍物边缘接触格子: %s (期望: true)", tostring(result3))
    
    -- 测试4：障碍物不覆盖格子
    local result4 = navmesh:check_obstacle_grid_overlap(50, 50, 5, 1, 1)  -- 障碍物中心(50,50)，半径5，格子(1,1)
    log.info("测试4 - 障碍物不覆盖格子: %s (期望: false)", tostring(result4))
    
    -- 测试5：障碍物覆盖格子角落
    local result5 = navmesh:check_obstacle_grid_overlap(5, 5, 3, 1, 1)  -- 障碍物中心(5,5)，半径3，格子(1,1)
    log.info("测试5 - 障碍物覆盖格子角落: %s (期望: true)", tostring(result5))
    
    log.info("重叠检测测试完成")
end

local function test_multiple_obstacles_state_management()
    log.info("开始多障碍物状态管理测试")
    
    local navmesh = Simple2DNavMesh.new(100, 100, 10)
    
    -- 添加第一个障碍物
    navmesh:add_obstacle(25, 25, 15)  -- 影响格子(2,2)和(3,2)
    
    -- 检查受影响格子的状态
    local node1 = navmesh:get_node(25, 25)  -- 格子(2,2)
    local node2 = navmesh:get_node(35, 25)  -- 格子(3,2)
    
    log.info("添加第一个障碍物后:")
    log.info("  格子(25,25)可行走: %s, 障碍物影响数: %d", 
             tostring(node1.walkable), navmesh:count_obstacle_effects(node1))
    log.info("  格子(35,25)可行走: %s, 障碍物影响数: %d", 
             tostring(node2.walkable), navmesh:count_obstacle_effects(node2))
    
    -- 添加第二个障碍物（与第一个重叠）
    navmesh:add_obstacle(35, 25, 10)
    
    log.info("添加第二个障碍物后:")
    log.info("  格子(25,25)可行走: %s, 障碍物影响数: %d", 
             tostring(node1.walkable), navmesh:count_obstacle_effects(node1))
    log.info("  格子(35,25)可行走: %s, 障碍物影响数: %d", 
             tostring(node2.walkable), navmesh:count_obstacle_effects(node2))
    
    -- 移除第一个障碍物
    navmesh:remove_obstacle(25, 25, 15)
    
    log.info("移除第一个障碍物后:")
    log.info("  格子(25,25)可行走: %s, 障碍物影响数: %d", 
             tostring(node1.walkable), navmesh:count_obstacle_effects(node1))
    log.info("  格子(35,25)可行走: %s, 障碍物影响数: %d", 
             tostring(node2.walkable), navmesh:count_obstacle_effects(node2))
    
    -- 移除第二个障碍物
    navmesh:remove_obstacle(35, 25, 10)
    
    log.info("移除第二个障碍物后:")
    log.info("  格子(25,25)可行走: %s, 障碍物影响数: %d", 
             tostring(node1.walkable), navmesh:count_obstacle_effects(node1))
    log.info("  格子(35,25)可行走: %s, 障碍物影响数: %d", 
             tostring(node2.walkable), navmesh:count_obstacle_effects(node2))
    
    log.info("多障碍物状态管理测试完成")
end

local function test_edge_cases()
    log.info("开始边界情况测试")
    
    local navmesh = Simple2DNavMesh.new(100, 100, 10)
    
    -- 测试边界障碍物
    navmesh:add_obstacle(5, 5, 8)  -- 边界附近的障碍物
    
    local node = navmesh:get_node(5, 5)
    log.info("边界障碍物测试: 格子(5,5)可行走=%s", tostring(node and node.walkable or false))
    
    -- 测试大半径障碍物
    navmesh:add_obstacle(50, 50, 30)  -- 大半径障碍物
    
    local affected_count = 0
    for y = 1, navmesh.grid_height do
        for x = 1, navmesh.grid_width do
            local node = navmesh.grid[y][x]
            if not node.walkable then
                affected_count = affected_count + 1
            end
        end
    end
    
    log.info("大半径障碍物测试: 受影响格子数=%d", affected_count)
    
    -- 移除障碍物
    navmesh:remove_obstacle(5, 5, 8)
    navmesh:remove_obstacle(50, 50, 30)
    
    -- 检查是否完全恢复
    local walkable_count = 0
    for y = 1, navmesh.grid_height do
        for x = 1, navmesh.grid_width do
            local node = navmesh.grid[y][x]
            if node.walkable then
                walkable_count = walkable_count + 1
            end
        end
    end
    
    log.info("恢复测试: 可行走格子数=%d, 总格子数=%d", walkable_count, navmesh.grid_width * navmesh.grid_height)
    
    log.info("边界情况测试完成")
end

local function test_performance_comparison()
    log.info("开始性能对比测试")
    
    local navmesh = Simple2DNavMesh.new(500, 500, 10)  -- 50x50网格
    
    -- 测试添加多个障碍物的性能
    local start_time = skynet.now()
    
    for i = 1, 20 do
        navmesh:add_obstacle(50 + i * 20, 50 + i * 20, 15)
    end
    
    local add_time = skynet.now() - start_time
    
    -- 测试移除障碍物的性能
    start_time = skynet.now()
    
    for i = 1, 20 do
        navmesh:remove_obstacle(50 + i * 20, 50 + i * 20, 15)
    end
    
    local remove_time = skynet.now() - start_time
    
    log.info("性能测试结果:")
    log.info("  添加20个障碍物耗时: %.3f 毫秒", add_time * 1000)
    log.info("  移除20个障碍物耗时: %.3f 毫秒", remove_time * 1000)
    log.info("  平均每个障碍物添加耗时: %.3f 毫秒", add_time * 1000 / 20)
    log.info("  平均每个障碍物移除耗时: %.3f 毫秒", remove_time * 1000 / 20)
    
    log.info("性能对比测试完成")
end

-- 启动测试
skynet.start(function()
    test_overlap_detection()
    test_multiple_obstacles_state_management()
    test_edge_cases()
    test_performance_comparison()
    skynet.exit()
end) 