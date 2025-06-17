local skynet = require "skynet"
local class = require "utils.class"
local log = require "log"
local GridAOI = require "scene.grid_aoi"
local Terrain = require "scene.terrain"
local NavMesh = require "scene.pathfinding.navmesh"

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
    
    -- 初始化导航网格
    self.navmesh = NavMesh.new(self.terrain)
    
    -- 加载地形数据
    if config.terrain_data then
        self.terrain:load_terrain_data(config.terrain_data)
    end
end

-- 添加实体
function Scene:add_entity(entity)
    if self.entities[entity.id] then
        log.error("Entity %d already exists in scene %d", entity.id, self.scene_id)
        return false
    end
    
    -- 检查位置是否可通行
    if not self.terrain:is_walkable(entity.x, entity.y) then
        log.error("Cannot add entity %d to scene %d at position (%d,%d): terrain not walkable", 
            entity.id, self.scene_id, entity.x, entity.y)
        return false
    end
    
    self.entities[entity.id] = entity
    entity.scene = self
    
    -- 将实体加入AOI网格
    self.aoi:add_entity(entity)
    
    -- 通知周围的实体
    local surrounding = self:get_surrounding_entities(entity)
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
    local surrounding = self:get_surrounding_entities(entity)
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
        return false, "实体不存在"
    end
    
    -- 检查移动是否合法
    if not self.terrain:check_move(entity.x, entity.y, x, y) then
        return false, "无法移动到目标位置"
    end
    
    -- 获取移动前的周围实体
    local old_surrounding = self:get_surrounding_entities(entity)
    
    -- 更新位置
    local old_x, old_y = entity.x, entity.y
    entity.x = x
    entity.y = y
    
    -- 更新AOI网格
    self.aoi:move_entity(entity, old_x, old_y)
    
    -- 获取移动后的周围实体
    local new_surrounding = self:get_surrounding_entities(entity)
    
    -- 处理视野变化
    self:handle_view_change(entity, old_surrounding, new_surrounding)
    
    return true
end

-- 处理视野变化
function Scene:handle_view_change(entity, old_surrounding, new_surrounding)
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
function Scene:get_surrounding_entities(entity)
    return self.aoi:get_surrounding_entities(entity)
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

-- 寻路接口
function Scene:find_path(start_x, start_y, end_x, end_y)
    -- 使用导航网格寻路
    return self.navmesh:find_path(start_x, start_y, end_x, end_y)
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
    return not self.terrain:check_move(from_x, from_y, to_x, to_y)
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
end

-- 序列化场景数据
function Scene:serialize()
    local data = {
        scene_id = self.scene_id,
        config = self.config,
        entities = {}
    }
    
    -- 序列化实体数据
    for id, entity in pairs(self.entities) do
        -- 只序列化固定实体(怪物、NPC等)
        if entity.type == Entity.ENTITY_TYPE.MONSTER or 
           entity.type == Entity.ENTITY_TYPE.NPC then
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
    
    -- 恢复实体
    for _, entity_data in pairs(data.entities) do
        if entity_data.type == Entity.ENTITY_TYPE.MONSTER then
            local MonsterEntity = require "scene.monster_entity"
            local monster = MonsterEntity.new(entity_data.id, entity_data)
            self:add_entity(monster)
        elseif entity_data.type == Entity.ENTITY_TYPE.NPC then
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
    
    -- 更新AOI系统
    self.aoi:update()
    
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
    
    -- 清理其他资源
    self.entities = {}
    self.transport_points = {}
    self.safe_zones = {}
end

-- 销毁场景
function Scene:destroy()
    -- 清理资源
    self:cleanup()
    
    -- 通知所有实体场景销毁
    for _, entity in pairs(self.entities) do
        if entity.on_scene_destroy then
            entity:on_scene_destroy()
        end
    end
end

return Scene