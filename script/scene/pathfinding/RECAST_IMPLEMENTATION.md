# RecastNavigation Lua绑定实现

## 概述

本文档描述了在Skynet框架中实现的RecastNavigation Lua绑定，提供了高性能的3D导航网格寻路功能。

## 功能特性

### 1. 核心功能
- **导航网格构建**: 从地形数据自动生成导航网格
- **A*寻路算法**: 高效的路径查找
- **动态障碍物**: 支持运行时添加/移除障碍物
- **3D坐标支持**: 完整的3D空间寻路

### 2. 地形类型支持
- `1`: PLAIN（平地）- 可行走
- `2`: WATER（水域）- 不可行走
- `3`: MOUNTAIN（山地）- 不可行走
- `4`: OBSTACLE（障碍物）- 不可行走
- `5`: SAFE_ZONE（安全区）- 可行走
- `6`: TRANSPORT（传送点）- 可行走

## API接口

### 初始化
```lua
local recast = require "recast"
recast.init()  -- 初始化RecastNavigation
```

### 创建导航网格
```lua
local navmesh_config = {
    width = 20,           -- 地形宽度
    height = 20,          -- 地形高度
    terrain_data = {},    -- 地形数据（二维数组）
    cell_size = 1.0,      -- 网格大小
    cell_height = 0.5,    -- 网格高度
    walkable_slope_angle = 45.0  -- 可行走坡度角度
}

local navmesh_id = recast.create_navmesh(navmesh_config)
```

### 寻路
```lua
local path = recast.find_path(navmesh_id, start_x, start_y, start_z, end_x, end_y, end_z)
-- 返回路径点数组: {{x, y, z}, {x, y, z}, ...}
```

### 动态障碍物
```lua
-- 添加障碍物
local obstacle_id = recast.add_obstacle(navmesh_id, x, y, z, radius, height)

-- 移除障碍物
local success = recast.remove_obstacle(navmesh_id, obstacle_id)
```

### 资源管理
```lua
-- 销毁导航网格
recast.destroy_navmesh(navmesh_id)

-- 清理所有资源
recast.cleanup()
```

## 使用示例

### 基本使用
```lua
local recast = require "recast"

-- 初始化
recast.init()

-- 创建地形数据
local terrain_data = {}
for z = 1, 20 do
    terrain_data[z] = {}
    for x = 1, 20 do
        terrain_data[z][x] = 1  -- 平地
    end
end

-- 创建导航网格
local navmesh_id = recast.create_navmesh({
    width = 20,
    height = 20,
    terrain_data = terrain_data,
    cell_size = 1.0,
    cell_height = 0.5,
    walkable_slope_angle = 45.0
})

-- 寻路
local path = recast.find_path(navmesh_id, 1, 0, 1, 19, 0, 19)
if path then
    print("找到路径，点数:", #path)
end

-- 清理
recast.destroy_navmesh(navmesh_id)
```

### 在pathfindingS服务中使用
```lua
local RecastNavMesh = require "scene.pathfinding.recast_navmesh"

-- 创建RecastNavigation导航网格
local navmesh = RecastNavMesh.new(terrain)

-- 寻路
local path = navmesh:find_path(start_x, start_y, end_x, end_y)

-- 添加动态障碍物
local obstacle_id = navmesh:add_dynamic_obstacle(x, y, radius)

-- 移除动态障碍物
navmesh:remove_dynamic_obstacle(obstacle_id)
```

## 坐标系说明

RecastNavigation使用右手坐标系：
- **X轴**: 水平方向（东向）
- **Y轴**: 垂直方向（向上）
- **Z轴**: 水平方向（北向）

在2D游戏中，通常将：
- 游戏X坐标映射到RecastNavigation的Z坐标
- 游戏Y坐标映射到RecastNavigation的Y坐标
- RecastNavigation的X坐标用于深度信息

## 性能优化

### 1. 网格参数调优
- `cell_size`: 较小的值提供更精确的路径，但增加内存使用
- `cell_height`: 影响垂直精度
- `walkable_slope_angle`: 控制可行走的坡度

### 2. 动态障碍物
- 使用圆柱形障碍物，性能优于复杂几何体
- 合理设置障碍物半径和高度
- 及时移除不需要的障碍物

### 3. 内存管理
- 及时销毁不需要的导航网格
- 避免创建过多的小型导航网格
- 使用`cleanup()`清理所有资源

## 错误处理

### 常见错误
1. **初始化失败**: 检查RecastNavigation库是否正确编译
2. **创建导航网格失败**: 检查地形数据格式和参数
3. **寻路失败**: 检查起点和终点是否在可行走区域
4. **内存不足**: 减少网格精度或地形大小

### 调试建议
```lua
-- 启用详细日志
local log = require "log"
log.set_level("debug")

-- 检查导航网格状态
if navmesh_id then
    print("导航网格创建成功:", navmesh_id)
else
    print("导航网格创建失败")
end
```

## 与现有实现的比较

### 优势
- **性能**: 基于C++的高性能实现
- **精度**: 支持3D空间和复杂地形
- **功能**: 完整的动态障碍物支持
- **稳定性**: 成熟的商业级库

### 限制
- **内存使用**: 比纯Lua实现占用更多内存
- **动态更新**: 不支持地形类型的动态更新
- **复杂度**: 配置参数较多，需要调优

## 编译要求

确保RecastNavigation库已正确编译并链接：
```bash
# 检查库文件
ls 3rd/recastnavigation/

# 编译Lua绑定
make lualib-src
```

## 测试

运行测试文件验证功能：
```lua
local test = require "test.recast_test"
test()  -- 运行所有测试
``` 