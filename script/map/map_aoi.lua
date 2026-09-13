
local class = require "utils.class"
local aoi_object = require "map.aoi_object"

local MapAOI = class("MapAOI")

function MapAOI:ctor(width, height, grid_size)
    self.width = width
    self.height = height
    self.grid_size = grid_size or 50
    self.cols = math.ceil(width / self.grid_size)
    self.rows = math.ceil(height / self.grid_size)
    self.grids = {} -- grid_key => { [uid] = obj }
    self.obj_grids = {} -- uid => { {row, col} }
    self.objs = {} -- uid => AoiObj
    self.observers = {} -- uid => AoiObj（观察者单独索引，便于视野同步）
    self.observer_grids = {} -- grid_key => { [uid] = obs }（观察者按格子）
end

local function grid_key(row, col)
    return row * 10000 + col
end

function MapAOI:_grid_pos(x, y)
    local col = math.floor(x / self.grid_size) + 1
    local row = math.floor(y / self.grid_size) + 1
    col = math.max(1, math.min(col, self.cols))
    row = math.max(1, math.min(row, self.rows))
    return row, col
end

function MapAOI:_get_grid(row, col)
    local key = grid_key(row, col)
    local grid = self.grids[key]
    if not grid then
        grid = {}
        self.grids[key] = grid
    end
    return grid
end

function MapAOI:_get_observer_grid(row, col)
    local key = grid_key(row, col)
    local grid = self.observer_grids[key]
    if not grid then
        grid = {}
        self.observer_grids[key] = grid
    end
    return grid
end

function MapAOI:_add_to_grid(obj)
    local row, col = self:_grid_pos(obj.x, obj.y)
    local uid = obj.uid
    self:_get_grid(row, col)[uid] = obj
    self.obj_grids[uid] = { { row = row, col = col } }
    if aoi_object.is_observer(obj) then
        self:_get_observer_grid(row, col)[uid] = obj
    end
end

function MapAOI:_remove_from_grid(obj)
    local uid = obj.uid
    local cells = self.obj_grids[uid]
    if not cells then
        return
    end
    for _, pos in ipairs(cells) do
        local key = grid_key(pos.row, pos.col)
        local grid = self.grids[key]
        if grid then
            grid[uid] = nil
        end
        local ogrid = self.observer_grids[key]
        if ogrid then
            ogrid[uid] = nil
        end
    end
    self.obj_grids[uid] = nil
end

function MapAOI:_move_in_grid(obj, old_x, old_y, new_x, new_y)
    local old_row, old_col = self:_grid_pos(old_x, old_y)
    local new_row, new_col = self:_grid_pos(new_x, new_y)
    if old_row == new_row and old_col == new_col then
        return
    end
    local uid = obj.uid
    local old_key = grid_key(old_row, old_col)
    if self.grids[old_key] then
        self.grids[old_key][uid] = nil
    end
    self:_get_grid(new_row, new_col)[uid] = obj
    self.obj_grids[uid] = { { row = new_row, col = new_col } }
    if aoi_object.is_observer(obj) then
        local ogrid = self.observer_grids[old_key]
        if ogrid then
            ogrid[uid] = nil
        end
        self:_get_observer_grid(new_row, new_col)[uid] = obj
    end
end

-- 视野范围 = 中心格子 ± view_grids 圈
function MapAOI:_surrounding(obj, view_range)
    view_range = tonumber(view_range) or 0
    local view_grids = math.ceil(view_range / self.grid_size)
    local center_row, center_col = self:_grid_pos(obj.x, obj.y)
    local result = {}
    local self_uid = obj.uid
    for row = center_row - view_grids, center_row + view_grids do
        for col = center_col - view_grids, center_col + view_grids do
            if row >= 1 and row <= self.rows and col >= 1 and col <= self.cols then
                local grid = self.grids[grid_key(row, col)]
                if grid then
                    for uid, other in pairs(grid) do
                        if uid ~= self_uid then
                            result[#result + 1] = other
                        end
                    end
                end
            end
        end
    end
    return result
end

function MapAOI:enter(obj)
    local uid = obj.uid
    if uid == nil or uid == "" then
        return false, "invalid obj"
    end

    local incoming_ghost = aoi_object.is_ghost(obj)
    local existing = self.objs[uid]
    if existing then
        if incoming_ghost then
            if not aoi_object.is_ghost(existing) then
                return true
            end
            local old_x, old_y = existing.x, existing.y
            aoi_object.apply_ghost_update(existing, obj)
            self:_move_in_grid(existing, old_x, old_y, existing.x, existing.y)
            existing._aoi_x, existing._aoi_y = existing.x, existing.y
            return true, nil, existing.x, existing.y, existing.type, old_x, old_y
        end
        if aoi_object.is_ghost(existing) then
            self:_remove_from_grid(existing)
            self.objs[uid] = nil
            self.observers[uid] = nil
        else
            return true
        end
    end

    obj._aoi_x, obj._aoi_y = obj.x, obj.y
    self.objs[uid] = obj
    self:_add_to_grid(obj)
    if aoi_object.is_observer(obj) then
        self.observers[uid] = obj
    end
    return true, nil, obj.x, obj.y, obj.type
end

function MapAOI:leave(uid)
    local obj = self.objs[uid]
    if not obj then
        return true
    end
    local x, y, otype = obj.x, obj.y, obj.type
    self:_remove_from_grid(obj)
    self.objs[uid] = nil
    self.observers[uid] = nil
    return true, nil, x, y, otype
end

function MapAOI:remove_ghost(uid)
    local obj = self.objs[uid]
    if not obj or not aoi_object.is_ghost(obj) then
        return true
    end
    return self:leave(uid)
end

function MapAOI:move(uid, x, y)
    local obj = self.objs[uid]
    if not obj then
        return false, "not found"
    end
    local old_x = obj._aoi_x or obj.x
    local old_y = obj._aoi_y or obj.y
    obj.x = tonumber(x) or obj.x
    obj.y = tonumber(y) or obj.y
    obj._aoi_x, obj._aoi_y = obj.x, obj.y
    self:_move_in_grid(obj, old_x, old_y, obj.x, obj.y)
    return true, nil, obj.x, obj.y, obj.type, old_x, old_y
end

function MapAOI:get(uid)
    return self.objs[uid]
end

function MapAOI:list_surrounding(uid)
    local obj = self.objs[uid]
    if not obj then
        return {}
    end
    return self:_surrounding(obj, obj.view_range)
end

function MapAOI:around(x, y, view_range)
    return self:_surrounding({
        uid = nil,
        x = tonumber(x) or 0,
        y = tonumber(y) or 0,
    }, view_range)
end

-- 范围内观察者：只扫覆盖的格子
function MapAOI:observers_around(x, y, view_range)
    view_range = tonumber(view_range) or 0
    local view_grids = math.ceil(view_range / self.grid_size)
    local center_row, center_col = self:_grid_pos(x, y)
    local result = {}
    for row = center_row - view_grids, center_row + view_grids do
        for col = center_col - view_grids, center_col + view_grids do
            if row >= 1 and row <= self.rows and col >= 1 and col <= self.cols then
                local grid = self.observer_grids[grid_key(row, col)]
                if grid then
                    for _, obs in pairs(grid) do
                        result[#result + 1] = obs
                    end
                end
            end
        end
    end
    return result
end

return MapAOI
