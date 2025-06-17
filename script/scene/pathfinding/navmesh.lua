local class = require "utils.class"
local log = require "log"

-- 导航网格节点
local NavNode = class("NavNode")

function NavNode:ctor(id, center_x, center_y, connections)
    self.id = id
    self.x = center_x
    self.y = center_y
    self.connections = connections or {}  -- {node_id => cost}
    self.walkable = true
end

-- 导航网格
local NavMesh = class("NavMesh")

function NavMesh:ctor(terrain)
    self.terrain = terrain
    self.width = terrain.width
    self.height = terrain.height
    self.cell_size = terrain.grid_size
    
    -- 计算网格数量
    self.cols = math.ceil(self.width / self.cell_size)
    self.rows = math.ceil(self.height / self.cell_size)
    
    -- 初始化节点
    self.nodes = {}  -- {node_id => node}
    self.grid = {}   -- 快速查找节点的网格索引
    
    -- 根据地形构建导航网格
    self:build_from_terrain()
end

-- 根据地形构建导航网格
function NavMesh:build_from_terrain()
    -- 初始化网格
    for row = 1, self.rows do
        self.grid[row] = {}
        for col = 1, self.cols do
            local node_id = self:get_node_id(row, col)
            local center_x = (col - 0.5) * self.cell_size
            local center_y = (row - 0.5) * self.cell_size
            
            local node = NavNode.new(node_id, center_x, center_y)
            -- 根据地形设置节点是否可行走
            node.walkable = self.terrain:is_walkable(row, col)
            
            self.nodes[node_id] = node
            self.grid[row][col] = node
        end
    end
    
    -- 连接可行走的相邻节点
    for row = 1, self.rows do
        for col = 1, self.cols do
            if self.grid[row][col].walkable then
                self:connect_adjacent_nodes(row, col)
            end
        end
    end
end

-- 获取节点ID
function NavMesh:get_node_id(row, col)
    return row * 10000 + col
end

-- 连接相邻节点
function NavMesh:connect_adjacent_nodes(row, col)
    local directions = {
        {-1, 0},  -- 上
        {1, 0},   -- 下
        {0, -1},  -- 左
        {0, 1},   -- 右
        {-1, -1}, -- 左上
        {-1, 1},  -- 右上
        {1, -1},  -- 左下
        {1, 1}    -- 右下
    }
    
    local current_node = self.grid[row][col]
    
    for _, dir in ipairs(directions) do
        local next_row = row + dir[1]
        local next_col = col + dir[2]
        
        -- 检查是否在网格范围内
        if next_row >= 1 and next_row <= self.rows and 
           next_col >= 1 and next_col <= self.cols then
            local next_node = self.grid[next_row][next_col]
            
            -- 只连接可行走的节点
            if next_node.walkable then
                -- 检查对角线移动是否可行
                if dir[1] ~= 0 and dir[2] ~= 0 then
                    -- 检查两个相邻的格子是否都可行走(避免穿墙)
                    local walkable = self.grid[row][next_col].walkable and 
                                   self.grid[next_row][col].walkable
                    if walkable then
                        -- 对角线距离为1.414
                        current_node.connections[next_node.id] = 1.414
                    end
                else
                    -- 直线距离为1
                    current_node.connections[next_node.id] = 1
                end
            end
        end
    end
end

-- 更新导航网格(当地形发生变化时调用)
function NavMesh:update_area(start_x, start_y, end_x, end_y)
    local start_row = math.max(1, math.ceil(start_y / self.cell_size))
    local start_col = math.max(1, math.ceil(start_x / self.cell_size))
    local end_row = math.min(self.rows, math.ceil(end_y / self.cell_size))
    local end_col = math.min(self.cols, math.ceil(end_x / self.cell_size))
    
    -- 更新节点的可行走状态
    for row = start_row, end_row do
        for col = start_col, end_col do
            local node = self.grid[row][col]
            local old_walkable = node.walkable
            node.walkable = self.terrain:is_walkable(row, col)
            
            -- 如果可行走状态发生变化,需要更新连接
            if old_walkable ~= node.walkable then
                if node.walkable then
                    -- 如果变为可行走,添加连接
                    self:connect_adjacent_nodes(row, col)
                else
                    -- 如果变为不可行走,断开连接
                    for connected_id in pairs(node.connections) do
                        local connected_node = self.nodes[connected_id]
                        connected_node.connections[node.id] = nil
                        node.connections[connected_id] = nil
                    end
                end
            end
        end
    end
end

-- A*寻路算法
function NavMesh:find_path(start_x, start_y, end_x, end_y)
    local start_node = self:get_node_at(start_x, start_y)
    local end_node = self:get_node_at(end_x, end_y)
    
    if not start_node or not end_node or 
       not start_node.walkable or not end_node.walkable then
        return nil
    end
    
    local open_set = {[start_node.id] = true}
    local closed_set = {}
    local came_from = {}
    
    local g_score = {[start_node.id] = 0}
    local f_score = {[start_node.id] = self:heuristic(start_node, end_node)}
    
    while next(open_set) do
        -- 找到f_score最小的节点
        local current_id, current_node
        local min_f_score = math.huge
        
        for node_id in pairs(open_set) do
            if f_score[node_id] < min_f_score then
                min_f_score = f_score[node_id]
                current_id = node_id
                current_node = self.nodes[node_id]
            end
        end
        
        if current_id == end_node.id then
            -- 找到路径，重建路径
            return self:reconstruct_path(came_from, end_node)
        end
        
        open_set[current_id] = nil
        closed_set[current_id] = true
        
        -- 检查所有相邻节点
        for next_id, cost in pairs(current_node.connections) do
            if not closed_set[next_id] then
                local next_node = self.nodes[next_id]
                if next_node.walkable then
                    local tentative_g_score = g_score[current_id] + cost
                    
                    if not g_score[next_id] or tentative_g_score < g_score[next_id] then
                        came_from[next_id] = current_id
                        g_score[next_id] = tentative_g_score
                        f_score[next_id] = g_score[next_id] + self:heuristic(next_node, end_node)
                        open_set[next_id] = true
                    end
                end
            end
        end
    end
    
    return nil  -- 没有找到路径
end

-- 获取位置所在的节点
function NavMesh:get_node_at(x, y)
    local row = math.max(1, math.min(math.ceil(y / self.cell_size), self.rows))
    local col = math.max(1, math.min(math.ceil(x / self.cell_size), self.cols))
    return self.grid[row][col]
end

-- 启发式函数（使用欧几里得距离）
function NavMesh:heuristic(node1, node2)
    local dx = node2.x - node1.x
    local dy = node2.y - node1.y
    return math.sqrt(dx * dx + dy * dy)
end

-- 重建路径
function NavMesh:reconstruct_path(came_from, end_node)
    local path = {}
    local current_id = end_node.id
    
    while current_id do
        local node = self.nodes[current_id]
        table.insert(path, 1, {x = node.x, y = node.y})
        current_id = came_from[current_id]
    end
    
    return self:smooth_path(path)
end

-- 路径平滑处理
function NavMesh:smooth_path(path)
    if #path < 3 then return path end
    
    local smoothed = {path[1]}
    local current_index = 1
    
    while current_index < #path do
        local current = path[current_index]
        
        -- 找到可以直接到达的最远点
        local furthest_index = current_index
        for i = #path, current_index + 1, -1 do
            if self:is_clear_line(current.x, current.y, path[i].x, path[i].y) then
                furthest_index = i
                break
            end
        end
        
        if furthest_index > current_index + 1 then
            -- 跳过中间点
            current_index = furthest_index
        else
            current_index = current_index + 1
        end
        
        table.insert(smoothed, path[current_index])
    end
    
    return smoothed
end

-- 检查两点之间是否可以直线通过
function NavMesh:is_clear_line(x1, y1, x2, y2)
    -- 使用地形系统的移动检查
    return self.terrain:check_move(x1, y1, x2, y2)
end

return NavMesh 