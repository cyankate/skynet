local class = require "utils.class"
local log = require "log"
local recast = require "recast"

-- RecastNavigation导航网格
local RecastNavMesh = class("RecastNavMesh")

function RecastNavMesh:ctor(terrain)
    self.terrain = terrain
    self.width = terrain.width
    self.height = terrain.height
    self.cell_size = terrain.grid_size
    self.navmesh_id = nil
    self.obstacles = {}
    
    -- 初始化RecastNavigation
    if not recast.init() then
        log.error("RecastNavigation初始化失败")
        return
    end
    
    -- 构建导航网格
    self:build_from_terrain()
end

function RecastNavMesh:build_from_terrain()
    -- 准备地形数据
    local terrain_data = {}
    local cols = math.ceil(self.width / self.cell_size)
    local rows = math.ceil(self.height / self.cell_size)
    
    for row = 1, rows do
        terrain_data[row] = {}
        for col = 1, cols do
            local x = (col - 0.5) * self.cell_size
            local y = (row - 0.5) * self.cell_size
            local terrain_type = self.terrain:get_terrain_type(x, y)
            terrain_data[row][col] = terrain_type
        end
    end
    
    -- 创建导航网格配置
    local navmesh_config = {
        width = cols,
        height = rows,
        terrain_data = terrain_data,
        cell_size = self.cell_size,
        cell_height = 0.5,
        walkable_slope_angle = 45.0
    }
    
    -- 创建导航网格
    self.navmesh_id = recast.create_navmesh(navmesh_config)
    if not self.navmesh_id then
        log.error("创建RecastNavigation导航网格失败")
        return
    end
    
    log.info("RecastNavigation导航网格创建成功，ID: %d", self.navmesh_id)
end

function RecastNavMesh:find_path(start_x, start_y, end_x, end_y)
    if not self.navmesh_id then
        log.error("导航网格未初始化")
        return nil
    end
    
    -- 转换为3D坐标（Y轴向上）
    local start_z = start_x
    local start_y_3d = 0.0  -- 假设地面高度为0
    local end_z = end_x
    local end_y_3d = 0.0
    
    local path_3d = recast.find_path(self.navmesh_id, start_z, start_y_3d, start_y, end_z, end_y_3d, end_y)
    if not path_3d then
        log.warn("RecastNavigation寻路失败: (%.2f, %.2f) -> (%.2f, %.2f)", start_x, start_y, end_x, end_y)
        return nil
    end
    
    -- 转换回2D路径
    local path_2d = {}
    for i, point in ipairs(path_3d) do
        table.insert(path_2d, {
            x = point[1],  -- Z坐标映射到X
            y = point[3]   -- Y坐标映射到Y
        })
    end
    
    log.info("RecastNavigation寻路成功，路径点数: %d", #path_2d)
    return path_2d
end

function RecastNavMesh:add_dynamic_obstacle(x, y, radius)
    if not self.navmesh_id then
        log.error("导航网格未初始化")
        return nil
    end
    
    -- 转换为3D坐标
    local z = x
    local y_3d = 0.0
    local height = 3.0  -- 默认障碍物高度
    
    local obstacle_id = recast.add_obstacle(self.navmesh_id, z, y_3d, y, radius, height)
    if obstacle_id then
        self.obstacles[obstacle_id] = {
            x = x,
            y = y,
            radius = radius,
            height = height
        }
        log.info("添加动态障碍物成功，ID: %d", obstacle_id)
        return obstacle_id
    else
        log.error("添加动态障碍物失败")
        return nil
    end
end

function RecastNavMesh:remove_dynamic_obstacle(obstacle_id)
    if not self.navmesh_id then
        log.error("导航网格未初始化")
        return false
    end
    
    if not self.obstacles[obstacle_id] then
        log.warn("障碍物不存在，ID: %d", obstacle_id)
        return false
    end
    
    if recast.remove_obstacle(self.navmesh_id, obstacle_id) then
        self.obstacles[obstacle_id] = nil
        log.info("移除动态障碍物成功，ID: %d", obstacle_id)
        return true
    else
        log.error("移除动态障碍物失败，ID: %d", obstacle_id)
        return false
    end
end

function RecastNavMesh:update_terrain_type(x, y, new_terrain_type)
    -- RecastNavigation不支持动态更新地形类型
    -- 需要重新构建整个导航网格
    log.warn("RecastNavigation不支持动态更新地形类型，需要重新构建导航网格")
    return false
end

function RecastNavMesh:is_walkable(x, y)
    -- 简化实现，基于地形类型判断
    local terrain_type = self.terrain:get_terrain_type(x, y)
    local blocked_types = {[2] = true, [3] = true, [4] = true}  -- WATER, MOUNTAIN, OBSTACLE
    return not blocked_types[terrain_type]
end

function RecastNavMesh:get_node_at(x, y)
    -- RecastNavigation不直接暴露节点信息
    -- 返回简化的节点信息
    return {
        x = x,
        y = y,
        walkable = self:is_walkable(x, y)
    }
end

function RecastNavMesh:destroy()
    if self.navmesh_id then
        if recast.destroy_navmesh(self.navmesh_id) then
            log.info("销毁RecastNavigation导航网格成功")
        else
            log.error("销毁RecastNavigation导航网格失败")
        end
        self.navmesh_id = nil
    end
    
    self.obstacles = {}
end

-- 析构函数
function RecastNavMesh:dtor()
    self:destroy()
end

return RecastNavMesh 