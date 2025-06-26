local skynet = require "skynet"
local class = require "utils.class"
local log = require "log"
local GridAOI = require "scene.grid_aoi"
local Terrain = require "scene.terrain"
local Simple2DNavMesh = require "scene.pathfinding.simple_2d_navmesh"
local NPCMgr = require "scene.npc_mgr"

local Scene = class("Scene")

function Scene:ctor(scene_id, config)
    self.scene_id = scene_id
    self.config = config
    self.entities = {}  -- entity_id => entity_obj
    
    -- 初始化AOI网格系统
    self.aoi = GridAOI.new(
        config.width or 1000,    -- 场景宽度
        config.height or 1000,   -- 场景高度
        config.grid_size or 50   -- 网格大小
    )
    
    -- 初始化地形系统
    self.terrain = Terrain.new(
        config.width or 1000,
        config.height or 1000,
        config.grid_size or 50
    )
    
    -- 初始化导航网格系统
    self.navmesh = Simple2DNavMesh.new(
        config.width or 1000,
        config.height or 1000,
        config.grid_size or 50
    )
    
    -- 加载地形数据
    if config.terrain_data then
        self.terrain:load_terrain_data(config.terrain_data)
    end
    
    -- 同步地形数据到导航网格
    self:sync_terrain_to_navmesh()
    
    -- 初始化NPC管理器
    self.npc_mgr = NPCMgr.new(self)
    
    log.info("场景%d初始化完成: %dx%d, 网格大小: %d", 
             self.scene_id, self.terrain.width, self.terrain.height, self.terrain.grid_size)
end

-- 同步地形数据到导航网格
function Scene:sync_terrain_to_navmesh()
    log.info("开始同步地形数据到导航网格...")
    
    local terrain_data = {}
    local cols = self.terrain.cols
    local rows = self.terrain.rows
    
    for row = 1, rows do
        for col = 1, cols do
            local cell = self.terrain.grid[row][col]
            local world_x = (col - 0.5) * self.terrain.grid_size
            local world_y = (row - 0.5) * self.terrain.grid_size
            
            -- 转换地形类型到导航网格格式
            local navmesh_terrain_type = self:convert_terrain_type(cell.type)
            
            table.insert(terrain_data, {
                x = world_x,
                y = world_y,
                terrain_type = navmesh_terrain_type
            })
        end
    end
    
    -- 批量设置导航网格地形
    self.navmesh:set_terrain_batch(terrain_data)
    
    log.info("地形数据同步完成，共处理 %d 个网格", #terrain_data)
end

-- 转换地形类型
function Scene:convert_terrain_type(terrain_type)
    -- Terrain类型到Simple2DNavMesh类型的映射
    local type_mapping = {
        [Terrain.TERRAIN_TYPE.PLAIN] = 1,      -- 平地
        [Terrain.TERRAIN_TYPE.WATER] = 2,      -- 水域
        [Terrain.TERRAIN_TYPE.MOUNTAIN] = 3,   -- 山地
        [Terrain.TERRAIN_TYPE.OBSTACLE] = 4,   -- 障碍物
        [Terrain.TERRAIN_TYPE.SAFE_ZONE] = 5,  -- 安全区
        [Terrain.TERRAIN_TYPE.TRANSPORT] = 6,  -- 传送点
    }
    
    return type_mapping[terrain_type] or 1
end

-- 添加实体
function Scene:add_entity(entity)
    if self.entities[entity.id] then
        log.error("Entity %d already exists in scene %d", entity.id, self.scene_id)
        return false
    end
    
    -- 检查位置是否可通行
    if not self:is_position_walkable(entity.x, entity.y) then
        log.error("Cannot add entity %d to scene %d at position (%d,%d): terrain not walkable", 
            entity.id, self.scene_id, entity.x, entity.y)
        return false
    end
    
    self.entities[entity.id] = entity
    entity.scene = self
    
    -- 将实体加入AOI网格
    self.aoi:add_entity(entity)
    
    -- 通知周围的实体
    local surrounding = self:get_surrounding_entities(entity.id)
    for _, other in pairs(surrounding) do
        other:on_entity_enter(entity)
        entity:on_entity_enter(other)
    end
    
    return true
end

-- 移除实体
function Scene:remove_entity(entity_id)
    local entity = self.entities[entity_id]
    if not entity then
        return false
    end
    
    -- 通知周围的实体
    local surrounding = self:get_surrounding_entities(entity_id)
    for _, other in pairs(surrounding) do
        other:on_entity_leave(entity)
        entity:on_entity_leave(other)
    end
    
    -- 从AOI网格中移除
    self.aoi:remove_entity(entity)
    
    self.entities[entity_id] = nil
    entity.scene = nil
    
    return true
end

-- 移动实体
function Scene:move_entity(entity_id, x, y)
    local entity = self.entities[entity_id]
    if not entity then
        log.error("Scene:move_entity() not found, entity_id: %d", entity_id)
        return false
    end
    
    -- 检查移动是否合法
    if not self:can_move_to(entity.x, entity.y, x, y) then
        log.error("Scene:move_entity() can't move to, {x: %f, y: %f} -> {x: %f, y: %f}", entity.x, entity.y, x, y)
        return false
    end
    
    -- 获取移动前的周围实体
    local old_surrounding = self:get_surrounding_entities(entity_id)
    
    -- 更新位置
    local old_x, old_y = entity.x, entity.y
    entity.x = x
    entity.y = y
    
    -- 更新AOI网格
    self.aoi:move_entity(entity, old_x, old_y, x, y)
    
    -- 获取移动后的周围实体
    local new_surrounding = self:get_surrounding_entities(entity_id)
    
    -- 处理视野变化
    self:handle_view_change(entity_id, old_surrounding, new_surrounding)
    
    return true
end

-- 处理视野变化
function Scene:handle_view_change(entity_id, old_surrounding, new_surrounding)
    local entity = self.entities[entity_id]
    if not entity then
        return
    end
    
    -- 找出离开视野的实体
    for _, old in pairs(old_surrounding) do
        if not new_surrounding[old.id] then
            entity:on_entity_leave(old)
            old:on_entity_leave(entity)
        end
    end
    
    -- 找出进入视野的实体
    for _, new in pairs(new_surrounding) do
        if not old_surrounding[new.id] then
            entity:on_entity_enter(new)
            new:on_entity_enter(entity)
        end
    end
end

-- 获取周围实体
function Scene:get_surrounding_entities(entity_id, view_range)
    local entity = self.entities[entity_id]
    if not entity then
        return {}
    end
    view_range = view_range or entity.view_range
    return self.aoi:get_surrounding_entities(entity, view_range)
end

-- 获取实体
function Scene:get_entity(entity_id)
    return self.entities[entity_id]
end

-- 获取场景中的所有实体
function Scene:get_all_entities()
    return self.entities
end

-- 广播消息给场景中的所有实体
function Scene:broadcast_message(message_name, message_data)
    for _, entity in pairs(self.entities) do
        if entity.type == "player" then
            entity:send_message(message_name, message_data)
        end
    end
end

-- 寻路接口（使用Simple2DNavMesh）
function Scene:find_path(start_x, start_y, end_x, end_y, options)
    options = options or {}
    
    -- 检查起点和终点是否可行走
    if not self:is_position_walkable(start_x, start_y) then
        log.error("Scene:find_path() start_x: %f, start_y: %f is not walkable", start_x, start_y)
        return nil
    end
    
    if not self:is_position_walkable(end_x, end_y) then
        log.error("Scene:find_path() end_x: %f, end_y: %f is not walkable", end_x, end_y)
        return nil
    end
    
    -- 使用Simple2DNavMesh进行寻路
    local path = self.navmesh:find_path(start_x, start_y, end_x, end_y, options)
    
    if path then
        return path
    else
        log.warn("寻路失败: (%.1f, %.1f) -> (%.1f, %.1f)", start_x, start_y, end_x, end_y)
        return nil
    end
end

-- 检查位置是否可行走
function Scene:is_position_walkable(x, y)
    -- 首先检查是否在地图范围内
    if not self:is_position_valid(x, y) then
        return false
    end
    
    -- 使用导航网格检查是否可行走
    local node = self.navmesh:get_node(x, y)
    return node and node.walkable
end

-- 检查是否可以移动到目标位置
function Scene:can_move_to(from_x, from_y, to_x, to_y)
    -- 检查起点和终点是否可行走
    if not self:is_position_walkable(from_x, from_y) or 
       not self:is_position_walkable(to_x, to_y) then
        return false
    end
    
    -- 检查路径是否可行
    return self.navmesh:is_line_walkable(from_x, from_y, to_x, to_y)
end

-- 检查位置是否有效
function Scene:is_position_valid(x, y)
    -- 检查是否在地图范围内
    if x < 0 or x >= self.terrain.width or 
       y < 0 or y >= self.terrain.height then
        return false
    end
    return true
end

-- 检查是否有碰撞
function Scene:has_collision(from_x, from_y, to_x, to_y)
    return not self:can_move_to(from_x, from_y, to_x, to_y)
end

-- 检查位置是否安全区
function Scene:is_safe_zone(x, y)
    return self.terrain:get_terrain_type(x, y) == Terrain.TERRAIN_TYPE.SAFE_ZONE
end

-- 检查位置是否传送点
function Scene:is_transport_point(x, y)
    return self.terrain:get_terrain_type(x, y) == Terrain.TERRAIN_TYPE.TRANSPORT
end

-- 添加传送点
function Scene:add_transport_point(point)
    -- 更新地形数据
    local terrain_data = {
        x = point.x,
        y = point.y,
        type = Terrain.TERRAIN_TYPE.TRANSPORT,
        props = {
            target_scene = point.target_scene,
            target_x = point.target_x,
            target_y = point.target_y,
            name = point.name,
            cost = point.cost
        }
    }
    self.terrain:load_terrain_data({terrain_data})
    
    -- 同步到导航网格
    self.navmesh:set_terrain(point.x, point.y, 6)  -- 传送点类型
end

-- 添加安全区
function Scene:add_safe_zone(zone)
    -- 将区域内的所有格子设置为安全区
    local terrain_data = {}
    for x = zone.x, zone.x + zone.width, self.config.grid_size do
        for y = zone.y, zone.y + zone.height, self.config.grid_size do
            table.insert(terrain_data, {
                x = x,
                y = y,
                type = Terrain.TERRAIN_TYPE.SAFE_ZONE,
                props = {
                    name = zone.name
                }
            })
        end
    end
    self.terrain:load_terrain_data(terrain_data)
    
    -- 同步到导航网格
    for _, data in ipairs(terrain_data) do
        self.navmesh:set_terrain(data.x, data.y, 5)  -- 安全区类型
    end
end

-- 添加动态障碍物
function Scene:add_dynamic_obstacle(x, y, radius)
    return self.navmesh:add_obstacle(x, y, radius)
end

-- 移除动态障碍物
function Scene:remove_dynamic_obstacle(x, y, radius)
    return self.navmesh:remove_obstacle(x, y, radius)
end

-- 更新地形类型
function Scene:update_terrain_type(x, y, new_terrain_type)
    -- 更新地形系统
    local row = math.ceil(y / self.terrain.grid_size)
    local col = math.ceil(x / self.terrain.grid_size)
    
    if row >= 1 and row <= self.terrain.rows and col >= 1 and col <= self.terrain.cols then
        self.terrain.grid[row][col].type = new_terrain_type
        self.terrain.grid[row][col].walkable = not self.terrain:is_blocked_type(new_terrain_type)
    end
    
    -- 同步到导航网格
    local navmesh_type = self:convert_terrain_type(new_terrain_type)
    self.navmesh:set_terrain(x, y, navmesh_type)
    
    log.info("更新地形类型: (%.1f, %.1f) -> %d", x, y, new_terrain_type)
end

-- 获取导航网格统计信息
function Scene:get_navmesh_stats()
    return self.navmesh:get_stats()
end

-- 序列化场景数据
function Scene:serialize()
    local data = {
        scene_id = self.scene_id,
        config = self.config,
        entities = {},
        terrain = self.terrain:serialize(),
        navmesh_stats = self:get_navmesh_stats()
    }
    
    -- 序列化实体数据
    for id, entity in pairs(self.entities) do
        -- 只序列化固定实体(怪物、NPC等)
        if entity.type == "monster" or entity.type == "npc" then
            data.entities[id] = {
                id = entity.id,
                type = entity.type,
                x = entity.x,
                y = entity.y,
                -- 其他需要保存的实体属性...
            }
        end
    end
    
    return data
end

-- 反序列化场景数据
function Scene:deserialize(data)
    -- 恢复场景配置
    self.config = data.config
    
    -- 恢复地形数据
    if data.terrain then
        self.terrain:deserialize(data.terrain)
        -- 重新同步到导航网格
        self:sync_terrain_to_navmesh()
    end
    
    -- 恢复实体
    for _, entity_data in pairs(data.entities) do
        if entity_data.type == "monster" then
            local MonsterEntity = require "scene.monster_entity"
            local monster = MonsterEntity.new(entity_data.id, entity_data)
            self:add_entity(monster)
        elseif entity_data.type == "npc" then
            local NPCEntity = require "scene.npc_entity"
            local npc = NPCEntity.new(entity_data.id, entity_data)
            self:add_entity(npc)
        end
    end
end

-- 更新场景
function Scene:update()
    local now = skynet.now() / 100
    
    -- 更新所有实体
    for _, entity in pairs(self.entities) do
        if entity.update then
            entity:update()
        end
    end
    
    -- 更新地形系统(如果有动态地形)
    if self.terrain.update then
        self.terrain:update()
    end
end

-- 清理场景资源
function Scene:cleanup()
    -- 移除所有实体
    for id, _ in pairs(self.entities) do
        self:remove_entity(id)
    end
    
    -- 清理AOI系统
    self.aoi:destroy()
    
    -- 清理地形系统
    if self.terrain.cleanup then
        self.terrain:cleanup()
    end
    
    -- 清理导航网格
    if self.navmesh.clear_cache then
        self.navmesh:clear_cache()
    end
    
    -- 清理其他资源
    self.entities = {}
end

-- 销毁场景
function Scene:destroy()
    -- 通知所有实体场景销毁
    for _, entity in pairs(self.entities) do
        if entity.on_scene_destroy then
            entity:on_scene_destroy()
        end
    end
    -- 清理资源
    self:cleanup()
end

return Scene