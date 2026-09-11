-- 大世界空间索引：持有 AoiObj 引用 + ghost 覆盖。不负责玩法权威。
local class = require "utils.class"
local GridAOI = require "scene.grid_aoi"
local aoi_object = require "map.aoi_object"

local MapAOI = class("MapAOI")

function MapAOI:ctor(width, height, grid_size)
    self.aoi = GridAOI.new(width, height, grid_size or 50)
    self.objs = {} -- uid => AoiObj
end

function MapAOI:enter(obj)
    local uid = aoi_object.uid_of(obj)
    if uid == nil or uid == "" then
        return false, "invalid obj"
    end
    aoi_object.ensure(obj)

    local incoming_ghost = aoi_object.is_ghost(obj)
    local existing = self.objs[uid]
    if existing then
        if incoming_ghost then
            if not aoi_object.is_ghost(existing) then
                return true
            end
            local old_x, old_y = existing.x, existing.y
            aoi_object.apply_ghost_update(existing, obj)
            self.aoi:move_entity(existing, old_x, old_y, existing.x, existing.y)
            existing._aoi_x, existing._aoi_y = existing.x, existing.y
            return true, nil, existing.x, existing.y, existing.type, old_x, old_y
        end
        if aoi_object.is_ghost(existing) then
            self.aoi:remove_entity(existing)
            self.objs[uid] = nil
        else
            return true
        end
    end

    obj._aoi_x, obj._aoi_y = obj.x, obj.y
    self.objs[uid] = obj
    self.aoi:add_entity(obj)
    return true, nil, obj.x, obj.y, obj.type
end

function MapAOI:leave(uid)
    uid = tostring(uid)
    local obj = self.objs[uid]
    if not obj then
        return true
    end
    local x, y, otype = obj.x, obj.y, obj.type
    self.aoi:remove_entity(obj)
    self.objs[uid] = nil
    return true, nil, x, y, otype
end

function MapAOI:remove_ghost(uid)
    local obj = self.objs[tostring(uid)]
    if not obj or not aoi_object.is_ghost(obj) then
        return true
    end
    return self:leave(uid)
end

function MapAOI:move(uid, x, y)
    local obj = self.objs[tostring(uid)]
    if not obj then
        return false, "not found"
    end
    local old_x = obj._aoi_x or obj.x
    local old_y = obj._aoi_y or obj.y
    obj.x = tonumber(x) or obj.x
    obj.y = tonumber(y) or obj.y
    obj._aoi_x, obj._aoi_y = obj.x, obj.y
    self.aoi:move_entity(obj, old_x, old_y, obj.x, obj.y)
    return true, nil, obj.x, obj.y, obj.type, old_x, old_y
end

function MapAOI:get(uid)
    return self.objs[tostring(uid)]
end

function MapAOI:list_surrounding(uid)
    local obj = self.objs[tostring(uid)]
    if not obj then
        return {}
    end
    local around = self.aoi:get_surrounding_entities(obj, obj.view_range) or {}
    local list = {}
    for _, other in pairs(around) do
        list[#list + 1] = other
    end
    return list
end

function MapAOI:around(x, y, view_range)
    view_range = tonumber(view_range) or 0
    local dummy = {
        id = 0,
        uid = 0,
        x = tonumber(x) or 0,
        y = tonumber(y) or 0,
        view_range = view_range,
    }
    local around = self.aoi:get_surrounding_entities(dummy, view_range) or {}
    local list = {}
    for _, other in pairs(around) do
        list[#list + 1] = other
    end
    return list
end

return MapAOI
