local skynet = require "skynet"
local log = require "log"
local service_ctx = require "runtime.service_ctx"
local Scene = require "scene.scene"
local Entity = require "scene.entity"

local M = service_ctx.get("scene.scene_service", {})
local UPDATE_INTERVAL = 0.1

local function get_scene()
    return M.scene
end

function M.init()
    if M._inited then
        return
    end
    M._inited = true
    local bind = package.loaded["scene.worker_bind"]
    M.map_id = bind and bind.map_id
    M.shard_id = bind and bind.shard_id
    skynet.fork(function()
        while true do
            if M.scene then
                M.scene:update()
            end
            skynet.sleep(UPDATE_INTERVAL * 100)
        end
    end)
    log.info("Scene service initialized, map_id=%s shard_id=%s", tostring(M.map_id), tostring(M.shard_id))
end

function M.ensure_scene(config)
    if M.scene then
        return true
    end
    if not M.map_id then
        return false, "scene worker missing map_id"
    end
    M.scene = Scene.new(M.map_id, config or {})
    return true
end

function M.destroy_scene()
    if M.scene then
        M.scene:destroy()
        M.scene = nil
    end
    return true
end

function M.enter_scene(entity_data)
    local scene = get_scene()
    if not scene then
        return false, "场景不存在"
    end

    local incoming_ghost = entity_data.properties and entity_data.properties.is_ghost
    local existing = scene:get_entity(entity_data.id)
    if existing then
        local existing_ghost = existing.properties and existing.properties.is_ghost
        if incoming_ghost then
            if not existing_ghost then
                return true
            end
            existing.ignore_walkable = true
            for k, v in pairs(entity_data.properties or {}) do
                existing:set_property(k, v)
            end
            return scene:move_entity(entity_data.id, entity_data.x or existing.x, entity_data.y or existing.y)
        end
        if existing_ghost then
            scene:remove_entity(entity_data.id)
        else
            return true
        end
    end

    local entity = Entity.new(entity_data.id, entity_data.type)
    for k, v in pairs(entity_data.properties or {}) do
        entity:set_property(k, v)
    end
    entity:set_position(entity_data.x or 0, entity_data.y or 0)
    if entity_data.view_range then
        entity.view_range = entity_data.view_range
    end
    entity.ignore_walkable = entity_data.ignore_walkable and true or false

    if not entity:enter_scene(scene) then
        return false, "进入场景失败"
    end

    return true
end

function M.remove_ghost(entity_id)
    local scene = get_scene()
    if not scene then
        return true
    end
    local entity = scene:get_entity(entity_id)
    if not entity then
        return true
    end
    if not (entity.properties and entity.properties.is_ghost) then
        return true
    end
    return scene:remove_entity(entity_id)
end

function M.leave_scene(entity_id)
    local scene = get_scene()
    if not scene then
        return false, "场景不存在"
    end
    return scene:remove_entity(entity_id)
end

function M.move_entity(entity_id, x, y)
    local scene = get_scene()
    if not scene then
        return false, "场景不存在"
    end
    return scene:move_entity(entity_id, x, y)
end

local function pack_entity(entity)
    return {
        id = entity.id,
        type = entity.type,
        x = entity.x,
        y = entity.y,
        properties = entity.properties or {},
    }
end

function M.get_entity(entity_id)
    local scene = get_scene()
    if not scene then
        return nil
    end
    local entity = scene:get_entity(entity_id)
    if not entity then
        return nil
    end
    return pack_entity(entity)
end

-- 跨服务只回普通 table，避免把带 scene 回指的 Entity 对象打包出去
function M.list_surrounding(entity_id)
    local scene = get_scene()
    if not scene then
        return {}
    end
    local surrounding = scene:get_surrounding_entities(entity_id) or {}
    local list = {}
    for _, entity in pairs(surrounding) do
        list[#list + 1] = pack_entity(entity)
    end
    return list
end

return M
