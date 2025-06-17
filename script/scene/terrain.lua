local class = require "utils.class"
local log = require "log"

local Terrain = class("Terrain")

function Terrain:ctor(width, height, grid_size)
    self.width = width
    self.height = height
    self.grid_size = grid_size
    
    -- 计算网格数量
    self.cols = math.ceil(width / grid_size)
    self.rows = math.ceil(height / grid_size)
    
    -- 初始化地形网格
    self.grid = {}
    for row = 1, self.rows do
        self.grid[row] = {}
        for col = 1, self.cols do
            self.grid[row][col] = {
                walkable = true,  -- 是否可行走
                height = 0,       -- 地形高度
                type = 1,         -- 地形类型(1:平地 2:水域 3:山地等)
            }
        end
    end
end

-- 设置区域地形属性
function Terrain:set_area(start_x, start_y, end_x, end_y, props)
    local start_row = math.max(1, math.ceil(start_y / self.grid_size))
    local start_col = math.max(1, math.ceil(start_x / self.grid_size))
    local end_row = math.min(self.rows, math.ceil(end_y / self.grid_size))
    local end_col = math.min(self.cols, math.ceil(end_x / self.grid_size))
    
    for row = start_row, end_row do
        for col = start_col, end_col do
            local cell = self.grid[row][col]
            for k, v in pairs(props) do
                cell[k] = v
            end
        end
    end
end

-- 检查位置是否可行走
function Terrain:is_walkable(row, col)
    if row < 1 or row > self.rows or col < 1 or col > self.cols then
        return false
    end
    return self.grid[row][col].walkable
end

-- 检查两点之间是否可以直线移动
function Terrain:check_move(x1, y1, x2, y2)
    local dx = x2 - x1
    local dy = y2 - y1
    local distance = math.sqrt(dx * dx + dy * dy)
    local steps = math.ceil(distance / (self.grid_size * 0.5))
    
    for i = 1, steps - 1 do
        local t = i / steps
        local x = x1 + dx * t
        local y = y1 + dy * t
        
        local row = math.ceil(y / self.grid_size)
        local col = math.ceil(x / self.grid_size)
        
        if not self:is_walkable(row, col) then
            return false
        end
    end
    
    return true
end

-- 获取地形高度
function Terrain:get_height(x, y)
    local row = math.ceil(y / self.grid_size)
    local col = math.ceil(x / self.grid_size)
    
    if row < 1 or row > self.rows or col < 1 or col > self.cols then
        return 0
    end
    
    return self.grid[row][col].height
end

-- 获取地形类型
function Terrain:get_type(x, y)
    local row = math.ceil(y / self.grid_size)
    local col = math.ceil(x / self.grid_size)
    
    if row < 1 or row > self.rows or col < 1 or col > self.cols then
        return 1  -- 默认为平地
    end
    
    return self.grid[row][col].type
end

-- 序列化地形数据
function Terrain:serialize()
    local data = {
        width = self.width,
        height = self.height,
        grid_size = self.grid_size,
        grid = {}
    }
    
    for row = 1, self.rows do
        data.grid[row] = {}
        for col = 1, self.cols do
            data.grid[row][col] = {
                walkable = self.grid[row][col].walkable,
                height = self.grid[row][col].height,
                type = self.grid[row][col].type
            }
        end
    end
    
    return data
end

-- 反序列化地形数据
function Terrain:deserialize(data)
    self.width = data.width
    self.height = data.height
    self.grid_size = data.grid_size
    
    self.rows = math.ceil(self.height / self.grid_size)
    self.cols = math.ceil(self.width / self.grid_size)
    
    self.grid = {}
    for row = 1, self.rows do
        self.grid[row] = {}
        for col = 1, self.cols do
            self.grid[row][col] = {
                walkable = data.grid[row][col].walkable,
                height = data.grid[row][col].height,
                type = data.grid[row][col].type
            }
        end
    end
end

return Terrain