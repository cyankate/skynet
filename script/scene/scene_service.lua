local log = require "log"
local service_ctx = require "runtime.service_ctx"
local scene_mgr = require "scene.scene_mgr"
local Entity = require "scene.entity"

local M = service_ctx.get("scene.scene_service", {})

function M.init()
    if M._inited then
        return
    end
    M._inited = true
    scene_mgr.init()
    log.info("Scene service initialized")
end

function M.create_scene(scene_id, config)
    local scene = scene_mgr.create_scene(scene_id, config)
    if not scene then
        return false, "创建场景失败"
    end
    return true
end

function M.destroy_scene(scene_id)
    return scene_mgr.destroy_scene(scene_id)
end

function M.enter_scene(scene_id, entity_data)
    local scene = scene_mgr.get_scene(scene_id)
    if not scene then
        return false, "场景不存在"
    end

    local entity = Entity.new(entity_data.id, entity_data.type)
    for k, v in pairs(entity_data.properties or {}) do
        entity:set_property(k, v)
    end
    entity:set_position(entity_data.x or 0, entity_data.y or 0)
    if entity_data.view_range then
        entity.view_range = entity_data.view_range
    end

    if not entity:enter_scene(scene) then
        return false, "进入场景失败"
    end

    return true
end

function M.leave_scene(scene_id, entity_id)
    local scene = scene_mgr.get_scene(scene_id)
    if not scene then
        return false, "场景不存在"
    end
    return scene:remove_entity(entity_id)
end

function M.move_entity(scene_id, entity_id, x, y)
    local scene = scene_mgr.get_scene(scene_id)
    if not scene then
        return false, "场景不存在"
    end
    return scene:move_entity(entity_id, x, y)
end

function M.get_surrounding_entities(scene_id, entity_id)
    local scene = scene_mgr.get_scene(scene_id)
    if not scene then
        return {}
    end
    return scene:get_surrounding_entities(entity_id)
end

function M.broadcast_scene(scene_id, message, exclude_entity_id)
    local scene = scene_mgr.get_scene(scene_id)
    if not scene then
        return false, "场景不存在"
    end

    local entities = scene.entities
    local count = 0
    for entity_id, _ in pairs(entities) do
        if entity_id ~= exclude_entity_id then
            count = count + 1
        end
    end
    return true, count
end

return M
