# 路径查找系统使用文档

## 概述

本系统提供了两种路径查找解决方案：

1. **RecastNavigation**：专业的3D路径查找系统，基于C++实现，性能优异
2. **Simple2DNavMesh**：轻量级的2D网格导航系统，纯Lua实现，易于使用

## 架构

```
┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐
│   其他服务      │    │  pathfindingS   │    │   recast.lua    │
│  (游戏逻辑)     │◄──►│   (服务层)      │◄──►│   (高级接口)    │
└─────────────────┘    └─────────────────┘    └─────────────────┘
                                                       │
                                              ┌─────────────────┐
                                              │   lrecast.c     │
                                              │   (C库接口)     │
                                              └─────────────────┘
                                                       │
                                              ┌─────────────────┐
                                              │ RecastNavigation│
                                              │   (底层库)      │
                                              └─────────────────┘
```

## 系统选择指南

### 使用RecastNavigation的场景：
- **3D游戏**：需要处理高度信息的复杂地形
- **大型地图**：需要高精度的导航网格
- **性能要求高**：需要处理大量并发寻路请求
- **专业游戏**：需要成熟的路径查找解决方案

### 使用Simple2DNavMesh的场景：
- **2D游戏**：平台跳跃、策略游戏、RPG
- **简单场景**：室内地图、小规模战斗
- **原型开发**：快速验证游戏机制
- **移动游戏**：性能要求高的场景

### 使用ParallelPathfinding的场景：
- **大型3D游戏**：需要处理复杂地形和大量并发寻路
- **MMO游戏**：大量玩家同时寻路
- **开放世界**：大地图、多区域寻路
- **性能优化**：需要并行处理多个寻路请求
- **复杂地形**：需要跨区域寻路优化

## 文件结构

```
script/scene/pathfinding/
├── recast.lua              # RecastNavigation高级接口
├── simple_2d_navmesh.lua   # 简单2D网格导航系统
├── parallel_pathfinding.lua # 并行寻路优化（基于RecastNavigation）
└── README.md               # 本文档

script/service/
└── pathfindingS.lua        # 路径查找服务

script/test/
├── pathfinding_test.lua    # RecastNavigation测试
├── simple_2d_navmesh_test.lua # Simple2DNavMesh测试
└── parallel_pathfinding_test.lua # 并行寻路测试
```

## 使用方法

### RecastNavigation（推荐）

#### 1. 启动路径查找服务

```lua
-- 在游戏启动时启动服务
local pathfinding_service = skynet.newservice("pathfindingS")

-- 初始化
local init_result = skynet.call(pathfinding_service, "lua", "init")
if not init_result then
    log.error("路径查找服务初始化失败")
end
```

#### 2. 创建导航网格

```lua
-- 从高度图创建
local heightmap = {
    width = 100,
    height = 100,
    data = {}  -- 二维数组，存储高度值
}

-- 生成高度图数据示例
for y = 0, heightmap.height - 1 do
    heightmap.data[y] = {}
    for x = 0, heightmap.width - 1 do
        -- 示例：创建一些地形变化
        local height = 0
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

local navmesh_id = skynet.call(pathfinding_service, "lua", "create_navmesh_from_heightmap", heightmap, {
    cell_size = 0.3,
    cell_height = 0.2,
    walkable_slope_angle = 45
})
```

#### 从三角形网格创建

```lua
-- 准备三角形数据
local triangles = {
    {vertices = {{0,0,0}, {1,0,0}, {0,0,1}}, walkable = true},
    {vertices = {{1,0,0}, {1,0,1}, {0,0,1}}, walkable = true},
    {vertices = {{0,0,1}, {1,0,1}, {0,1,1}}, walkable = true},
    {vertices = {{1,0,1}, {1,1,1}, {0,1,1}}, walkable = true},
    -- 障碍物三角形
    {vertices = {{5,0,5}, {6,0,5}, {5,0,6}}, walkable = false},
    {vertices = {{6,0,5}, {6,0,6}, {5,0,6}}, walkable = false},
    -- ... 更多三角形
}

-- 创建导航网格
local navmesh_id = skynet.call(pathfinding_service, "lua", "create_navmesh_from_triangles", triangles, {
    cell_size = 0.3,
    cell_height = 0.2
})
```

#### 3. 执行寻路

```lua
local path = skynet.call(pathfinding_service, "lua", "find_path", navmesh_id, 
    {start_x, start_y, start_z},  -- 起点
    {end_x, end_y, end_z},        -- 终点
    {max_path_length = 256}
)
```

#### 4. 批量寻路

```lua
local requests = {
    {
        id = 1,
        navmesh_id = navmesh_id,
        start_pos = {0, 0, 0},
        end_pos = {10, 0, 10},
        options = {max_path_length = 128}
    },
    {
        id = 2,
        navmesh_id = navmesh_id,
        start_pos = {5, 0, 5},
        end_pos = {15, 0, 15},
        options = {max_path_length = 128}
    }
}

local results = skynet.call(pathfinding_service, "lua", "find_paths_batch", requests)

for i, result in ipairs(results) do
    if result.path then
        print(string.format("寻路%d成功，路径点数: %d", i, #result.path))
    else
        print(string.format("寻路%d失败: %s", i, result.error))
    end
end
```

#### 5. 动态障碍物管理

```lua
-- 添加动态障碍物
local obstacle_data = {
    x = 10, y = 0, z = 10,  -- 障碍物位置
    radius = 2.0,           -- 半径
    height = 5.0            -- 高度
}

local obstacle_id = skynet.call(pathfinding_service, "lua", "add_obstacle", navmesh_id, obstacle_data)

-- 移除动态障碍物
local success = skynet.call(pathfinding_service, "lua", "remove_obstacle", navmesh_id, obstacle_id)
```

#### 6. 缓存优化

```lua
-- 预热常用路径缓存
local common_paths = {
    {start_pos = {0, 0, 0}, end_pos = {10, 0, 10}},
    {start_pos = {10, 0, 10}, end_pos = {20, 0, 20}},
    -- ... 更多常用路径
}

local warmed_count = skynet.call(pathfinding_service, "lua", "warmup_cache", navmesh_id, common_paths)

-- 获取缓存统计
local stats = skynet.call(pathfinding_service, "lua", "get_cache_stats")
print(string.format("导航网格: %d, 路径缓存: %d", stats.navmesh_count, stats.path_cache_count))
```

#### 7. 资源管理

```lua
-- 获取导航网格信息
local info = skynet.call(pathfinding_service, "lua", "get_navmesh_info", navmesh_id)

-- 销毁导航网格
local success = skynet.call(pathfinding_service, "lua", "destroy_navmesh", navmesh_id)

-- 清理所有资源
skynet.call(pathfinding_service, "lua", "cleanup")
```

### 并行寻路系统（ParallelPathfinding）

并行寻路系统基于RecastNavigation，提供高性能的并行寻路功能：

#### 1. 创建并行寻路器

```lua
local RecastAPI = require "scene.pathfinding.recast"
local ParallelPathfinder = require "scene.pathfinding.parallel_pathfinding"

-- 初始化RecastNavigation
RecastAPI.init()

-- 创建导航网格
local navmesh_id = RecastAPI.create_navmesh_from_heightmap(heightmap, config)

-- 创建并行寻路器
local pathfinder = ParallelPathfinder.new(navmesh_id)
```

#### 2. 单次寻路

```lua
local path = pathfinder:find_path(start_x, start_y, start_z, end_x, end_y, end_z, options)
if path then
    print(string.format("寻路成功，路径点数: %d", #path))
else
    print("寻路失败")
end
```

#### 3. 批量寻路

```lua
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
    }
}

local results = pathfinder:find_paths_batch(requests)
for i, result in ipairs(results) do
    if result.path then
        print(string.format("批量寻路%d成功，路径点数: %d", i, #result.path))
    else
        print(string.format("批量寻路%d失败: %s", i, result.error))
    end
end
```

#### 4. 缓存管理

```lua
-- 获取缓存统计
local stats = pathfinder:get_cache_stats()
print(string.format("路径缓存: %d, 区域缓存: %d, 区域数量: %d", 
     stats.path_cache_count, stats.region_cache_count, stats.region_count))

-- 清理缓存
pathfinder:clear_cache()
```

#### 5. 并行寻路特性

- **区域分割**：自动将导航网格分割为多个区域
- **并行处理**：跨区域寻路时并行处理各区域内的路径段
- **智能缓存**：路径缓存和区域路径缓存
- **路径平滑**：自动平滑处理路径，减少不必要的转向
- **边界优化**：优化区域间的连接点选择

### Simple2DNavMesh

#### 1. 创建导航网格

```lua
local Simple2DNavMesh = require "scene.pathfinding.simple_2d_navmesh"

-- 创建100x100的网格，每个格子大小为2
local navmesh = Simple2DNavMesh.new(100, 100, 2)
```

#### 2. 设置地形

```lua
-- 设置地形类型
navmesh:set_terrain(20, 20, 2)  -- 水域
navmesh:set_terrain(30, 30, 3)  -- 山地
navmesh:set_terrain(40, 40, 4)  -- 障碍物
```

#### 3. 执行寻路

```lua
local path = navmesh:find_path(10, 10, 50, 50, {
    smooth = true,
    smooth_factor = 0.3
})
```

## 迁移说明

### 从navmesh.lua迁移

原来的`navmesh.lua`（自适应三角形导航网格）已被删除，原因：

1. **功能重复**：RecastNavigation提供了更强大的功能
2. **性能优势**：C++实现性能远超Lua实现
3. **维护简化**：减少重复代码，降低维护成本
4. **标准化**：使用业界认可的解决方案

### 迁移步骤

1. **3D复杂场景**：使用RecastNavigation
2. **2D简单场景**：使用Simple2DNavMesh
3. **更新代码**：将`require "scene.pathfinding.navmesh"`替换为相应的新系统

## 性能优化建议

### RecastNavigation
1. **合理设置网格参数**：根据游戏需求调整cell_size和cell_height
2. **使用路径缓存**：对常用路径进行预热
3. **批量处理**：使用批量寻路减少服务调用次数
4. **及时清理**：不需要的导航网格及时销毁

### Simple2DNavMesh
1. **合理设置网格大小**：平衡精度和性能
2. **使用路径缓存**：避免重复计算
3. **批量操作**：使用批量寻路和地形设置
4. **定期清理缓存**：避免内存泄漏

## 错误处理

所有API都会返回错误信息：

```lua
local result, error = skynet.call(pathfinding_service, "lua", "find_path", navmesh_id, start, end)
if not result then
    log.error("寻路失败: %s", error)
end
```

常见错误：
- `"Invalid parameters"`: 参数无效
- `"Navmesh not found"`: 导航网格不存在
- `"No path found"`: 找不到路径
- `"起点或终点超出范围"`: 坐标超出网格范围
- `"起点或终点不可通行"`: 起点或终点被阻挡
- `"Failed to create navmesh"`: 创建导航网格失败
- `"Obstacle not found"`: 动态障碍物不存在
- `"Invalid obstacle data"`: 障碍物数据无效

## 测试

### RecastNavigation测试
```lua
skynet.newservice("service/pathfinding_test")
```

### Simple2DNavMesh测试
```lua
skynet.newservice("service/simple_2d_navmesh_test")
```

### 动态障碍物性能测试
```lua
skynet.newservice("service/dynamic_obstacle_fixed_test")
```

### ParallelPathfinding测试
```lua
skynet.newservice("service/parallel_pathfinding_test")
```

## 总结

- **navmesh.lua已删除**：功能已被RecastNavigation和Simple2DNavMesh替代
- **RecastNavigation**：专业的3D路径查找解决方案
- **Simple2DNavMesh**：轻量级的2D网格导航系统
- **按需选择**：根据项目需求选择合适的系统

## 配置参数说明

### 网格参数
- `cell_size`: 网格单元大小，影响精度和性能
- `cell_height`: 网格单元高度，影响垂直精度
- `walkable_slope_angle`: 可行走坡度，超过此角度的斜坡不可行走
- `walkable_height`: 可行走高度，角色能通过的最小高度
- `walkable_radius`: 可行走半径，角色半径
- `walkable_climb`: 可行走攀爬高度，角色能爬上的最大高度

### 区域参数
- `min_region_area`: 最小区域面积，小于此面积的区域会被合并
- `merge_region_area`: 合并区域面积，用于优化导航网格

### 轮廓参数
- `max_edge_len`: 最大边长，影响路径平滑度
- `max_edge_error`: 最大边误差，影响路径精度

### 细节参数
- `detail_sample_dist`: 细节采样距离
- `detail_sample_max_error`: 细节采样最大误差 