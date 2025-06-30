local skynet = require "skynet"
local service_wrapper = require "utils.service_wrapper"
local scene_mgr = require "scene.scene_mgr"
local log = require "log"

-- 创建场景
function CMD.create_scene(scene_id, config)
    local scene = scene_mgr.create_scene(scene_id, config)
    if not scene then
        return false, "创建场景失败"
    end
    return true
end

-- 销毁场景
function CMD.destroy_scene(scene_id)
    return scene_mgr.destroy_scene(scene_id)
end

-- 实体进入场景
function CMD.enter_scene(scene_id, entity_data)
    local scene = scene_mgr.get_scene(scene_id)
    if not scene then
        return false, "场景不存在"
    end
    
    local Entity = require "scene.entity"
    local entity = Entity.new(entity_data.id, entity_data.type)
    
    -- 设置实体属性
    for k, v in pairs(entity_data.properties or {}) do
        entity:set_property(k, v)
    end
    
    -- 设置实体位置
    entity:set_position(entity_data.x or 0, entity_data.y or 0)
    
    -- 设置视野范围
    if entity_data.view_range then
        entity.view_range = entity_data.view_range
    end
    
    -- 进入场景
    if not entity:enter_scene(scene) then
        return false, "进入场景失败"
    end
    
    return true
end

-- 实体离开场景
function CMD.leave_scene(scene_id, entity_id)
    local scene = scene_mgr.get_scene(scene_id)
    if not scene then
        return false, "场景不存在"
    end
    
    return scene:remove_entity(entity_id)
end

-- 实体移动
function CMD.move_entity(scene_id, entity_id, x, y)
    local scene = scene_mgr.get_scene(scene_id)
    if not scene then
        return false, "场景不存在"
    end
    
    return scene:move_entity(entity_id, x, y)
end

-- 获取实体周围的其他实体
function CMD.get_surrounding_entities(scene_id, entity_id)
    local scene = scene_mgr.get_scene(scene_id)
    if not scene then
        return {}
    end
    
    return scene:get_surrounding_entities(entity_id)
end

-- 广播场景消息
function CMD.broadcast_scene(scene_id, message, exclude_entity_id)
    local scene = scene_mgr.get_scene(scene_id)
    if not scene then
        return false, "场景不存在"
    end
    
    local entities = scene.entities
    local count = 0
    
    for entity_id, entity in pairs(entities) do
        if entity_id ~= exclude_entity_id then
            -- 这里应该调用实体的消息处理方法
            -- entity:handle_message(message)
            count = count + 1
        end
    end
    
    return true, count
end


local function main()
    -- 初始化场景管理器
    scene_mgr.init()
    log.info("Scene service initialized")
end

service_wrapper.create_service(main, {
    name = "scene",
})