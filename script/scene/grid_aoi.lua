local skynet = require "skynet"
local class = require "utils.class"
local log = require "log"

local GridAOI = class("GridAOI")

function GridAOI:ctor(width, height, grid_size)
    self.width = width
    self.height = height
    self.grid_size = grid_size
    
    -- 计算网格数量
    self.cols = math.ceil(width / grid_size)
    self.rows = math.ceil(height / grid_size)
    
    -- 初始化网格
    self.grids = {}  -- {row_col => {entity_id => entity}}
    self.entity_grids = {}  -- {entity_id => {row_col}}
end

-- 获取实体所在的网格坐标
function GridAOI:get_grid_pos(x, y)
    local col = math.floor(x / self.grid_size) + 1
    local row = math.floor(y / self.grid_size) + 1
    
    -- 确保在合法范围内
    col = math.max(1, math.min(col, self.cols))
    row = math.max(1, math.min(row, self.rows))
    
    return row, col
end

-- 获取网格的key
function GridAOI:get_grid_key(row, col)
    return row * 10000 + col
end

-- 获取指定网格
function GridAOI:get_grid(row, col)
    local key = self:get_grid_key(row, col)
    if not self.grids[key] then
        self.grids[key] = {}
    end
    return self.grids[key]
end

-- 获取实体影响的网格范围
function GridAOI:get_entity_affect_grids(entity)
    local view_grids = math.ceil(entity.view_range / self.grid_size)
    local center_row, center_col = self:get_grid_pos(entity.x, entity.y)
    
    local affected = {}
    for row = center_row - view_grids, center_row + view_grids do
        for col = center_col - view_grids, center_col + view_grids do
            -- 检查网格是否在场景范围内
            if row >= 1 and row <= self.rows and col >= 1 and col <= self.cols then
                table.insert(affected, {row = row, col = col})
            end
        end
    end
    
    return affected
end

-- 添加实体到网格
function GridAOI:add_entity(entity)
    local row, col = self:get_grid_pos(entity.x, entity.y)
    local grid = self:get_grid(row, col)
    grid[entity.id] = entity
    
    -- 记录实体所在的网格
    self.entity_grids[entity.id] = {{row = row, col = col}}
end

-- 从网格中移除实体
function GridAOI:remove_entity(entity)
    local grids = self.entity_grids[entity.id]
    if not grids then
        return
    end
    
    for _, grid_pos in ipairs(grids) do
        local key = self:get_grid_key(grid_pos.row, grid_pos.col)
        if self.grids[key] then
            self.grids[key][entity.id] = nil
        end
    end
    
    self.entity_grids[entity.id] = nil
end

-- 移动实体
function GridAOI:move_entity(entity, old_x, old_y, new_x, new_y)
    local old_row, old_col = self:get_grid_pos(old_x, old_y)
    local new_row, new_col = self:get_grid_pos(new_x, new_y)
    
    -- 如果没有跨越网格，不需要更新
    if old_row == new_row and old_col == new_col then
        return
    end
    
    -- 从旧网格移除
    local old_key = self:get_grid_key(old_row, old_col)
    if self.grids[old_key] then
        self.grids[old_key][entity.id] = nil
    end
    
    -- 添加到新网格
    local new_key = self:get_grid_key(new_row, new_col)
    local new_grid = self:get_grid(new_row, new_col)
    new_grid[entity.id] = entity
    
    -- 更新实体所在网格记录
    self.entity_grids[entity.id] = {{row = new_row, col = new_col}}
end

-- 获取周围实体
function GridAOI:get_surrounding_entities(entity, view_range)
    local affected_grids = self:get_entity_affect_grids(entity)
    local result = {}
    
    for _, grid_pos in ipairs(affected_grids) do
        local grid = self:get_grid(grid_pos.row, grid_pos.col)
        for _, other in pairs(grid) do
            if other.id ~= entity.id then
                -- 计算实际距离
                local dx = other.x - entity.x
                local dy = other.y - entity.y
                local distance = math.sqrt(dx * dx + dy * dy)
                
                -- 在视野范围内的实体
                if distance <= view_range then
                    result[other.id] = other
                end
            end
        end
    end
    
    return result
end

-- 销毁AOI系统
function GridAOI:destroy()
    self.grids = {}
    self.entity_grids = {}
end

return GridAOI