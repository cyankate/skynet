local class = require "utils.class"
local log = require "log"

local Terrain = class("Terrain")

-- 地形类型常量
Terrain.TERRAIN_TYPE = {
    PLAIN = 1,        -- 平地
    WATER = 2,        -- 水域
    MOUNTAIN = 3,     -- 山地
    OBSTACLE = 4,     -- 障碍物/不可通行
    SAFE_ZONE = 5,    -- 安全区
    TRANSPORT = 6,    -- 传送点
}

-- 文件顶部或模块内定义
local blocked_types = {
    [Terrain.TERRAIN_TYPE.OBSTACLE] = true,
    [Terrain.TERRAIN_TYPE.WATER] = true,
    [Terrain.TERRAIN_TYPE.MOUNTAIN] = true,
}

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
                type = Terrain.TERRAIN_TYPE.PLAIN,  -- 默认平地
                props = {},       -- 额外属性
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

-- 批量加载地形数据
function Terrain:load_terrain_data(terrain_data)
    -- terrain_data: { {x=, y=, type=, props={}}, ... }
    for _, data in ipairs(terrain_data) do
        local row = math.ceil((data.y or 0) / self.grid_size)
        local col = math.ceil((data.x or 0) / self.grid_size)
        if row >= 1 and row <= self.rows and col >= 1 and col <= self.cols then
            local cell = self.grid[row][col]
            if data.type then
                cell.type = data.type
                cell.walkable = not blocked_types[data.type]
            end
            if data.height then
                cell.height = data.height
            end
            if data.props then
                cell.props = data.props
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

-- 获取地形类型（推荐新接口）
function Terrain:get_terrain_type(x, y)
    local row = math.ceil(y / self.grid_size)
    local col = math.ceil(x / self.grid_size)
    if row < 1 or row > self.rows or col < 1 or col > self.cols then
        return Terrain.TERRAIN_TYPE.PLAIN
    end
    return self.grid[row][col].type
end

-- 兼容旧接口
function Terrain:get_type(x, y)
    return self:get_terrain_type(x, y)
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
                type = self.grid[row][col].type,
                props = self.grid[row][col].props,
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
                type = data.grid[row][col].type,
                props = data.grid[row][col].props,
            }
        end
    end
end

-- 检查地形类型是否被阻塞
function Terrain:is_blocked_type(terrain_type)
    return blocked_types[terrain_type] == true
end

return Terrain