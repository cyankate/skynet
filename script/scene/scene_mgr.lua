local skynet = require "skynet"
local Scene = require "scene.scene"
local log = require "log"
local NavMesh = require "scene.pathfinding.navmesh"
local ParallelPathfinder = require "scene.pathfinding.parallel_pathfinding"

local scene_mgr = {}

-- 场景列表
local scenes = {}  -- scene_id => scene_obj

-- 场景更新间隔(秒)
local UPDATE_INTERVAL = 0.1

-- 地形类型定义
scene_mgr.TERRAIN_TYPE = {
    PLAIN = 1,      -- 平地
    WATER = 2,      -- 水域
    MOUNTAIN = 3,   -- 山地
    OBSTACLE = 4,   -- 障碍物
    SAFE_ZONE = 5,  -- 安全区
    TRANSPORT = 6   -- 传送点
}

-- 测试地形类
local TestTerrain = {}

function TestTerrain:new(width, height, grid_size)
    local o = {
        width = width,
        height = height,
        grid_size = grid_size,
        terrain_data = {}
    }
    setmetatable(o, {__index = TestTerrain})
    
    -- 初始化为平地
    for y = 1, height do
        o.terrain_data[y] = {}
        for x = 1, width do
            o.terrain_data[y][x] = scene_mgr.TERRAIN_TYPE.PLAIN
        end
    end
    
    return o
end

function TestTerrain:get_terrain_type(x, y)
    local row = math.ceil(y / self.grid_size)
    local col = math.ceil(x / self.grid_size)
    return self.terrain_data[row] and self.terrain_data[row][col] or scene_mgr.TERRAIN_TYPE.OBSTACLE
end

function TestTerrain:set_terrain_type(x, y, type)
    local row = math.ceil(y / self.grid_size)
    local col = math.ceil(x / self.grid_size)
    if self.terrain_data[row] then
        self.terrain_data[row][col] = type
    end
end

function TestTerrain:set_area_terrain(start_x, start_y, end_x, end_y, type)
    local start_row = math.ceil(start_y / self.grid_size)
    local start_col = math.ceil(start_x / self.grid_size)
    local end_row = math.ceil(end_y / self.grid_size)
    local end_col = math.ceil(end_x / self.grid_size)
    
    for row = start_row, end_row do
        for col = start_col, end_col do
            if self.terrain_data[row] then
                self.terrain_data[row][col] = type
            end
        end
    end
end

function TestTerrain:check_move(x1, y1, x2, y2)
    -- 简单的直线可通行性检查
    local steps = math.max(math.abs(x2 - x1), math.abs(y2 - y1))
    if steps == 0 then return true end
    
    local dx = (x2 - x1) / steps
    local dy = (y2 - y1) / steps
    
    for i = 0, steps do
        local x = x1 + dx * i
        local y = y1 + dy * i
        local terrain_type = self:get_terrain_type(x, y)
        if NavMesh.BLOCKED_TERRAIN_TYPES[terrain_type] then
            return false
        end
    end
    return true
end

-- 创建测试场景
local function create_test_scene()
    local width = 100  -- 100米宽
    local height = 100 -- 100米高
    local grid_size = 1 -- 1米一个格子
    
    local terrain = TestTerrain:new(width, height, grid_size)
    
    -- 创建一些特殊地形区域
    -- 水域 - 创建一条蜿蜒的河流
    local river_points = {
        {x = 15, y = 20},  -- 起点
        {x = 20, y = 30},
        {x = 25, y = 35},
        {x = 23, y = 45},
        {x = 25, y = 55},
        {x = 30, y = 65},
        {x = 28, y = 75},
        {x = 25, y = 80}   -- 终点
    }
    
    -- 绘制河流主干
    for i = 1, #river_points - 1 do
        local start_x = river_points[i].x
        local start_y = river_points[i].y
        local end_x = river_points[i+1].x
        local end_y = river_points[i+1].y
        
        -- 计算每个段的步数
        local steps = math.max(math.abs(end_x - start_x), math.abs(end_y - start_y)) * 2
        
        -- 绘制河流主干
        for step = 0, steps do
            local t = step / steps
            local x = math.floor(start_x + (end_x - start_x) * t)
            local y = math.floor(start_y + (end_y - start_y) * t)
            
            -- 设置主河道
            terrain:set_terrain_type(x, y, scene_mgr.TERRAIN_TYPE.WATER)
            
            -- 添加河流宽度（不规则）
            local width = math.random(2, 4)  -- 河流宽度2-4格
            for w = -width, width do
                -- 使用正弦函数让河岸蜿蜒
                local offset = math.floor(math.sin(y * 0.1) * 1.5)
                terrain:set_terrain_type(x + w + offset, y, scene_mgr.TERRAIN_TYPE.WATER)
            end
        end
    end
    
    -- 添加一些支流
    local tributaries = {
        {start_x = 15, start_y = 25, end_x = 10, end_y = 30},
        {start_x = 25, start_y = 40, end_x = 30, end_y = 38},
        {start_x = 28, start_y = 70, end_x = 35, end_y = 72}
    }
    
    -- 绘制支流
    for _, trib in ipairs(tributaries) do
        local steps = math.max(math.abs(trib.end_x - trib.start_x), 
                             math.abs(trib.end_y - trib.start_y)) * 2
        
        for step = 0, steps do
            local t = step / steps
            local x = math.floor(trib.start_x + (trib.end_x - trib.start_x) * t)
            local y = math.floor(trib.start_y + (trib.end_y - trib.start_y) * t)
            
            -- 支流宽度较小
            local width = math.random(1, 2)
            for w = -width, width do
                terrain:set_terrain_type(x + w, y, scene_mgr.TERRAIN_TYPE.WATER)
            end
        end
    end
    
    -- 山地 - 创建两座山
    terrain:set_area_terrain(50, 10, 60, 30, scene_mgr.TERRAIN_TYPE.MOUNTAIN)
    terrain:set_area_terrain(50, 70, 60, 90, scene_mgr.TERRAIN_TYPE.MOUNTAIN)
    
    -- 障碍物 - 创建多个不规则建筑和障碍物
    -- L形建筑
    local function create_L_building(start_x, start_y, size)
        for x = start_x, start_x + size do
            terrain:set_terrain_type(x, start_y, scene_mgr.TERRAIN_TYPE.OBSTACLE)
        end
        for y = start_y, start_y + size do
            terrain:set_terrain_type(start_x, y, scene_mgr.TERRAIN_TYPE.OBSTACLE)
        end
    end
    
    -- U形建筑
    local function create_U_building(start_x, start_y, width, height)
        for x = start_x, start_x + width do
            terrain:set_terrain_type(x, start_y, scene_mgr.TERRAIN_TYPE.OBSTACLE)
            terrain:set_terrain_type(x, start_y + height, scene_mgr.TERRAIN_TYPE.OBSTACLE)
        end
        for y = start_y, start_y + height do
            terrain:set_terrain_type(start_x, y, scene_mgr.TERRAIN_TYPE.OBSTACLE)
            terrain:set_terrain_type(start_x + width, y, scene_mgr.TERRAIN_TYPE.OBSTACLE)
        end
    end
    
    -- 不规则多边形
    local function create_irregular_polygon(center_x, center_y, points)
        for i = 1, #points do
            local start_x = center_x + points[i].x
            local start_y = center_y + points[i].y
            local end_x = center_x + points[i % #points + 1].x
            local end_y = center_y + points[i % #points + 1].y
            
            local steps = math.max(math.abs(end_x - start_x), math.abs(end_y - start_y)) * 2
            for step = 0, steps do
                local t = step / steps
                local x = math.floor(start_x + (end_x - start_x) * t)
                local y = math.floor(start_y + (end_y - start_y) * t)
                terrain:set_terrain_type(x, y, scene_mgr.TERRAIN_TYPE.OBSTACLE)
            end
        end
    end
    
    -- 圆形障碍
    local function create_circle(center_x, center_y, radius)
        for angle = 0, 360, 5 do
            local rad = math.rad(angle)
            local x = math.floor(center_x + math.cos(rad) * radius)
            local y = math.floor(center_y + math.sin(rad) * radius)
            terrain:set_terrain_type(x, y, scene_mgr.TERRAIN_TYPE.OBSTACLE)
        end
    end
    
    -- 创建围墙（带缺口）
    local function create_wall_with_gaps(start_x, start_y, length, is_horizontal)
        local gap_start = math.random(math.floor(length / 4), math.floor(length / 2))
        local gap_size = math.random(2, 4)
        
        for i = 0, length do
            if i < gap_start or i > gap_start + gap_size then
                if is_horizontal then
                    terrain:set_terrain_type(start_x + i, start_y, scene_mgr.TERRAIN_TYPE.OBSTACLE)
                else
                    terrain:set_terrain_type(start_x, start_y + i, scene_mgr.TERRAIN_TYPE.OBSTACLE)
                end
            end
        end
    end
    
    -- 创建各种障碍物
    -- L形建筑群
    create_L_building(70, 40, 9)
    create_L_building(75, 45, 7)
    
    -- U形建筑
    create_U_building(40, 40, 8, 6)
    
    -- 不规则多边形（模拟岩石或废墟）
    create_irregular_polygon(60, 60, {
        {x = 0, y = 0},
        {x = 3, y = 1},
        {x = 4, y = 3},
        {x = 2, y = 4},
        {x = -1, y = 3},
        {x = -2, y = 1}
    })
    
    -- 圆形障碍（可能是水塔或圆形建筑）
    create_circle(85, 30, 5)
    create_circle(82, 35, 4)
    
    -- 围墙
    create_wall_with_gaps(65, 20, 15, true)  -- 横向围墙
    create_wall_with_gaps(90, 40, 12, false) -- 纵向围墙
    
    -- 随机小障碍物（模拟零散的岩石或障碍）
    for i = 1, 10 do
        local x = math.random(1, width)
        local y = math.random(1, height)
        -- 避免在水域和其他重要区域放置
        if terrain:get_terrain_type(x, y) == scene_mgr.TERRAIN_TYPE.PLAIN then
            create_irregular_polygon(x, y, {
                {x = math.random(-2, 2), y = math.random(-2, 2)},
                {x = math.random(-2, 2), y = math.random(-2, 2)},
                {x = math.random(-2, 2), y = math.random(-2, 2)}
            })
        end
    end
    
    -- 安全区 - 创建一个安全区
    terrain:set_area_terrain(80, 80, 90, 90, scene_mgr.TERRAIN_TYPE.SAFE_ZONE)
    
    -- 传送点 - 创建两个传送点
    terrain:set_terrain_type(40, 20, scene_mgr.TERRAIN_TYPE.TRANSPORT)
    terrain:set_terrain_type(40, 80, scene_mgr.TERRAIN_TYPE.TRANSPORT)
    
    return terrain
end

-- 测试用例
local test_cases = {
    {
        name = "简单路径",
        start_x = 10, start_y = 10,
        end_x = 15, end_y = 15,
        expected_result = true,
        description = "在平地上的简单路径"
    },
    {
        name = "绕过水域",
        start_x = 10, start_y = 50,
        end_x = 40, end_y = 50,
        expected_result = true,
        description = "需要绕过河流的路径"
    },
    {
        name = "绕过山地",
        start_x = 45, start_y = 20,
        end_x = 65, end_y = 20,
        expected_result = true,
        description = "需要绕过山地的路径"
    },
    {
        name = "复杂路径",
        start_x = 10, start_y = 10,
        end_x = 90, end_y = 90,
        expected_result = true,
        description = "需要绕过多个障碍的复杂路径"
    },
    {
        name = "不可达路径",
        start_x = 71, start_y = 45,
        end_x = 71, end_y = 55,
        expected_result = false,
        description = "被障碍物完全阻挡的路径"
    },
    {
        name = "传送点路径",
        start_x = 35, start_y = 20,
        end_x = 45, end_y = 80,
        expected_result = true,
        description = "通过传送点的路径"
    }
}

-- 测试接口
function scene_mgr.test_pathfinding()
    local terrain = create_test_scene()
    local navmesh = NavMesh.new(terrain)
    local pathfinder = ParallelPathfinder.new(navmesh)
    
    log.info("开始寻路测试...")
    
    -- 测试两种寻路方式
    local pathfinders = {
        {name = "NavMesh", finder = navmesh},
        {name = "ParallelPathfinder", finder = pathfinder}
    }
    
    for _, pf in ipairs(pathfinders) do
        log.info("========== 测试 %s ==========", pf.name)
        
        for _, test in ipairs(test_cases) do
            log.info("测试用例: %s", test.name)
            log.info("描述: %s", test.description)
            
            local start_time = skynet.now()
            local path
            if pf.name == "NavMesh" then
                path = pf.finder:find_path(test.start_x, test.start_y, test.end_x, test.end_y)
            else
                path = pf.finder:find_path(
                    test.start_x, test.start_y,
                    test.end_x, test.end_y,
                    {
                        --max_turn_angle = 45,
                        path_smooth = true
                    }
                )
            end
            local end_time = skynet.now()
            
            local success = (path ~= nil) == test.expected_result
            if success then
                log.info("测试通过! 耗时: %d ms", end_time - start_time)
                if path then
                    log.info("路径长度: %d", #path)
                    -- 打印路径点
                    for i, point in ipairs(path) do
                        log.info("路径点 %d: (%.2f, %.2f)", i, point.x, point.y)
                    end
                    
                    -- 验证路径的合法性
                    local valid = true
                    local total_distance = 0
                    for i = 1, #path - 1 do
                        local dx = path[i+1].x - path[i].x
                        local dy = path[i+1].y - path[i].y
                        local segment_distance = math.sqrt(dx * dx + dy * dy)
                        total_distance = total_distance + segment_distance
                        
                        if not terrain:check_move(path[i].x, path[i].y, path[i+1].x, path[i+1].y) then
                            valid = false
                            log.error("路径段 %d 到 %d 不可通行!", i, i+1)
                            break
                        end
                    end
                    if valid then
                        log.info("路径验证通过! 总距离: %.2f", total_distance)
                    end
                end
            else
                log.error("测试失败! 期望结果: %s, 实际结果: %s",
                    test.expected_result and "找到路径" or "无路径",
                    path and "找到路径" or "无路径"
                )
            end
            log.info("------------------------")
        end
    end
end

-- 可视化测试场景
function scene_mgr.visualize_test_scene()
    local terrain = create_test_scene()
    local result = {}
    
    -- 使用ASCII字符表示不同地形
    local terrain_chars = {
        [scene_mgr.TERRAIN_TYPE.PLAIN] = ".",      -- 平地
        [scene_mgr.TERRAIN_TYPE.WATER] = "~",      -- 水域
        [scene_mgr.TERRAIN_TYPE.MOUNTAIN] = "^",    -- 山地
        [scene_mgr.TERRAIN_TYPE.OBSTACLE] = "#",    -- 障碍物
        [scene_mgr.TERRAIN_TYPE.SAFE_ZONE] = "S",   -- 安全区
        [scene_mgr.TERRAIN_TYPE.TRANSPORT] = "T"    -- 传送点
    }
    
    -- 生成地图可视化
    for y = 1, terrain.height do
        local line = ""
        for x = 1, terrain.width do
            local type = terrain:get_terrain_type(x, y)
            line = line .. (terrain_chars[type] or "?")
        end
        table.insert(result, line)
    end
    
    -- 输出可视化结果
    log.info("地形可视化:")
    log.info("图例: . 平地  ~ 水域  ^ 山地  # 障碍物  S 安全区  T 传送点")
    log.info("------------------------")
    for _, line in ipairs(result) do
        log.info(line)
    end
end

-- 测试指定起点终点的寻路
function scene_mgr.test_specific_path(start_x, start_y, end_x, end_y, options)
    local terrain = create_test_scene()
    local navmesh = NavMesh.new(terrain)
    local pathfinder = ParallelPathfinder.new(navmesh)
    
    options = options or {
        max_turn_angle = 45,
        path_smooth = true
    }
    
    log.info("测试从 (%.2f, %.2f) 到 (%.2f, %.2f) 的寻路", start_x, start_y, end_x, end_y)
    
    -- 测试两种寻路方式
    local pathfinders = {
        {name = "NavMesh", finder = navmesh},
        {name = "ParallelPathfinder", finder = pathfinder}
    }
    
    for _, pf in ipairs(pathfinders) do
        log.info("========== 使用 %s ==========", pf.name)
        
        local start_time = skynet.now()
        local path
        if pf.name == "NavMesh" then
            path = pf.finder:find_path(start_x, start_y, end_x, end_y)
        else
            path = pf.finder:find_path(start_x, start_y, end_x, end_y, options)
        end
        local end_time = skynet.now()
        
        if path then
            log.info("找到路径! 路径长度: %d, 耗时: %d ms", #path, end_time - start_time)
            for i, point in ipairs(path) do
                log.info("路径点 %d: (%.2f, %.2f)", i, point.x, point.y)
            end
            
            -- 验证路径
            local total_distance = 0
            local valid = true
            for i = 1, #path - 1 do
                local dx = path[i+1].x - path[i].x
                local dy = path[i+1].y - path[i].y
                local segment_distance = math.sqrt(dx * dx + dy * dy)
                total_distance = total_distance + segment_distance
                
                if not terrain:check_move(path[i].x, path[i].y, path[i+1].x, path[i+1].y) then
                    valid = false
                    log.error("路径段 %d 到 %d 不可通行!", i, i+1)
                    break
                end
            end
            
            if valid then
                log.info("路径验证通过! 总距离: %.2f", total_distance)
            end
        else
            log.error("未找到可行路径! 耗时: %d ms", end_time - start_time)
        end
        log.info("------------------------")
    end
end

-- 性能测试
function scene_mgr.benchmark_pathfinding(num_tests)
    local terrain = create_test_scene()
    local navmesh = NavMesh.new(terrain)
    local pathfinder = ParallelPathfinder.new(navmesh)
    
    num_tests = num_tests or 1000
    
    -- 测试两种寻路方式
    local pathfinders = {
        {name = "NavMesh", finder = navmesh},
        {name = "ParallelPathfinder", finder = pathfinder}
    }
    
    for _, pf in ipairs(pathfinders) do
        log.info("========== %s 性能测试 ==========", pf.name)
        log.info("测试次数: %d", num_tests)
        
        local total_time = 0
        local success_count = 0
        local total_path_length = 0
        local max_time = 0
        local min_time = math.huge
        
        for i = 1, num_tests do
            -- 随机生成起点和终点
            local start_x = math.random(1, terrain.width)
            local start_y = math.random(1, terrain.height)
            local end_x = math.random(1, terrain.width)
            local end_y = math.random(1, terrain.height)
            
            local start_time = skynet.now()
            local path
            if pf.name == "NavMesh" then
                path = pf.finder:find_path(start_x, start_y, end_x, end_y)
            else
                path = pf.finder:find_path(start_x, start_y, end_x, end_y, {
                    max_turn_angle = 45,
                    path_smooth = true
                })
            end
            local end_time = skynet.now()
            local time_cost = end_time - start_time
            
            total_time = total_time + time_cost
            max_time = math.max(max_time, time_cost)
            min_time = math.min(min_time, time_cost)
            
            if path then
                success_count = success_count + 1
                total_path_length = total_path_length + #path
            end
        end
        
        log.info("测试结果:")
        log.info("成功率: %.2f%%", (success_count / num_tests) * 100)
        log.info("平均耗时: %.2f ms", total_time / num_tests)
        log.info("最大耗时: %d ms", max_time)
        log.info("最小耗时: %d ms", min_time)
        log.info("平均路径长度: %.2f", total_path_length / success_count)
        log.info("------------------------")
    end
end

-- 初始化
function scene_mgr.init()
    -- 可以在这里加载场景配置
    log.info("Scene manager initialized")
    scene_mgr.test_pathfinding()
    --scene_mgr.visualize_test_scene()
end

-- 创建场景
function scene_mgr.create_scene(scene_id, config)
    if scenes[scene_id] then
        log.error("Scene %d already exists", scene_id)
        return nil
    end
    
    local scene = Scene.new(scene_id, config)
    scenes[scene_id] = scene
    
    return scene
end

-- 获取场景
function scene_mgr.get_scene(scene_id)
    return scenes[scene_id]
end

-- 销毁场景
function scene_mgr.destroy_scene(scene_id)
    local scene = scenes[scene_id]
    if scene then
        scene:destroy()
        scenes[scene_id] = nil
    end
end

-- 更新所有场景
local function update()
    while true do
        -- 更新每个场景
        for _, scene in pairs(scenes) do
            scene:update()
        end
        
        -- 等待下一次更新
        skynet.sleep(UPDATE_INTERVAL * 100)  -- skynet.sleep的单位是0.01秒
    end
end

-- 启动场景管理器
function scene_mgr.start()
    -- 启动更新协程
    skynet.fork(update)
end

-- 停止场景管理器
function scene_mgr.stop()
    -- 销毁所有场景
    for scene_id, _ in pairs(scenes) do
        scene_mgr.destroy_scene(scene_id)
    end
end

-- 加载场景配置
function scene_mgr.load_scene_config(config_file)
    local config = require(config_file)
    
    for scene_id, scene_config in pairs(config) do
        -- 创建场景
        local scene = scene_mgr.create_scene(scene_id, scene_config)
        if scene then
            -- 加载地形数据
            if scene_config.terrain_data then
                scene:load_terrain(scene_config.terrain_data)
            end
            
            -- 加载NPC数据
            if scene_config.npcs then
                for _, npc_data in ipairs(scene_config.npcs) do
                    local NPCEntity = require "scene.npc_entity"
                    local npc = NPCEntity.new(npc_data.id, npc_data)
                    npc:set_position(npc_data.x, npc_data.y)
                    scene:add_entity(npc)
                end
            end
            
            -- 加载怪物数据
            if scene_config.monsters then
                for _, monster_data in ipairs(scene_config.monsters) do
                    local MonsterEntity = require "scene.monster_entity"
                    local monster = MonsterEntity.new(monster_data.id, monster_data)
                    monster:set_position(monster_data.x, monster_data.y)
                    scene:add_entity(monster)
                end
            end
            
            -- 加载传送点数据
            if scene_config.transport_points then
                for _, point in ipairs(scene_config.transport_points) do
                    scene:add_transport_point(point)
                end
            end
            
            -- 加载安全区数据
            if scene_config.safe_zones then
                for _, zone in ipairs(scene_config.safe_zones) do
                    scene:add_safe_zone(zone)
                end
            end
        end
    end
end

-- 保存场景数据
function scene_mgr.save_scene_data(scene_id, file_path)
    local scene = scenes[scene_id]
    if not scene then
        return false, "场景不存在"
    end
    
    -- 序列化场景数据
    local data = scene:serialize()
    
    -- 保存到文件
    local file = io.open(file_path, "w")
    if not file then
        return false, "无法打开文件"
    end
    
    file:write(skynet.packstring(data))
    file:close()
    
    return true
end

-- 加载场景数据
function scene_mgr.load_scene_data(scene_id, file_path)
    -- 读取文件
    local file = io.open(file_path, "r")
    if not file then
        return false, "无法打开文件"
    end
    
    local content = file:read("*a")
    file:close()
    
    -- 反序列化数据
    local ok, data = pcall(skynet.unpackstring, content)
    if not ok then
        return false, "数据格式错误"
    end
    
    -- 获取或创建场景
    local scene = scenes[scene_id]
    if not scene then
        scene = scene_mgr.create_scene(scene_id, data.config)
        if not scene then
            return false, "创建场景失败"
        end
    end
    
    -- 反序列化场景数据
    scene:deserialize(data)
    
    return true
end

-- 获取所有场景
function scene_mgr.get_all_scenes()
    return scenes
end

-- 传送玩家到指定场景
function scene_mgr.transport_player(player, target_scene_id, x, y)
    -- 获取目标场景
    local target_scene = scenes[target_scene_id]
    if not target_scene then
        return false, "目标场景不存在"
    end
    
    -- 从当前场景移除
    if player.scene then
        player:leave_scene()
    end
    
    -- 设置新位置
    player:set_position(x, y)
    
    -- 进入新场景
    return player:enter_scene(target_scene)
end

return scene_mgr