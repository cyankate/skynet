local class = require "utils.class"
local log = require "log"
local MinHeap = require "utils.min_heap"

-- 八个方向的偏移量（顺时针方向）
local DIRECTIONS = {
    {-1, 0},  -- 上
    {-1, 1},  -- 右上
    {0, 1},   -- 右
    {1, 1},   -- 右下
    {1, 0},   -- 下
    {1, -1},  -- 左下
    {0, -1},  -- 左
    {-1, -1}  -- 左上
}

-- 导航网格节点
local NavNode = class("NavNode")

function NavNode:ctor(id, center_x, center_y)
    self.id = id
    self.x = center_x
    self.y = center_y
    self.walkable = true
    self.terrain_type = nil
    self.blocked_count = 0
    self.row = nil  -- 将在初始化时设置
    self.col = nil  -- 将在初始化时设置
    -- 改用方向数组索引存储连接，节省内存
    self.connections = {}  -- {dir_index => cost}
end

-- 导航网格
local NavMesh = class("NavMesh")

-- 默认地形类型移动代价
NavMesh.DEFAULT_TERRAIN_COST = {
    [1] = 1,      -- PLAIN（平地）
    [2] = 2,      -- WATER（水域）
    [3] = 3,      -- MOUNTAIN（山地）
    [4] = 1,      -- OBSTACLE（障碍物）
    [5] = 1,      -- SAFE_ZONE（安全区）
    [6] = 0.5,    -- TRANSPORT（传送点）
}

-- 不可通行地形类型
NavMesh.BLOCKED_TERRAIN_TYPES = {
    [2] = true,   -- WATER（水域）
    [3] = true,   -- MOUNTAIN（山地）
    [4] = true,   -- OBSTACLE（障碍物）
}

-- 特殊地形类型
NavMesh.SPECIAL_TERRAIN = {
    TRANSPORT = 6,  -- 传送点
}

function NavMesh:ctor(terrain)
    self.terrain = terrain
    self.width = terrain.width
    self.height = terrain.height
    self.cell_size = terrain.grid_size
    self.cols = math.ceil(self.width / self.cell_size)
    self.rows = math.ceil(self.height / self.cell_size)
    self.nodes = {}  -- 节点id到节点的映射
    self.grid = {}   -- 网格坐标到节点的映射
    self.unit_terrain_cost = {}
    self.default_terrain_cost = NavMesh.DEFAULT_TERRAIN_COST
    self.dynamic_obstacles = {}
    -- 空间分区（简单网格分区）
    self.partition_size = 10  -- 每个分区10x10个格子
    self.partitions = {}
    -- 回调函数
    self.on_terrain_changed = nil
    -- 构建网格
    self:build_from_terrain()
    -- 初始化空间分区
    self:init_partitions()
end

-- 初始化空间分区
function NavMesh:init_partitions()
    local partition_rows = math.ceil(self.rows / self.partition_size)
    local partition_cols = math.ceil(self.cols / self.partition_size)
    for i = 1, partition_rows do
        self.partitions[i] = {}
        for j = 1, partition_cols do
            self.partitions[i][j] = {}
        end
    end
end

-- 获取节点所在的分区
function NavMesh:get_partition(row, col)
    local p_row = math.ceil(row / self.partition_size)
    local p_col = math.ceil(col / self.partition_size)
    return self.partitions[p_row][p_col]
end

-- 注册地形变化回调
function NavMesh:register_terrain_change_callback(callback)
    self.on_terrain_changed = callback
end

-- 更新地形类型
function NavMesh:update_terrain_type(x, y, new_terrain_type)
    local node = self:get_node_at(x, y)
    if not node then return end
    
    local old_terrain_type = node.terrain_type
    if old_terrain_type == new_terrain_type then return end
    
    node.terrain_type = new_terrain_type
    node.walkable = not NavMesh.BLOCKED_TERRAIN_TYPES[new_terrain_type] and node.blocked_count == 0
    
    -- 更新连接
    self:update_node_connections(node.row, node.col)
    
    -- 触发回调
    if self.on_terrain_changed then
        self.on_terrain_changed(x, y, old_terrain_type, new_terrain_type)
    end
end

-- 带选项的A*寻路算法
function NavMesh:find_path_with_options(start_x, start_y, end_x, end_y, unit_type, options)
    options = options or {}
    local max_turn_angle = options.max_turn_angle  -- 最大转向角度
    local path_smooth = options.path_smooth ~= false  -- 默认开启路径平滑
    
    local start_node = self:get_node_at(start_x, start_y)
    local end_node = self:get_node_at(end_x, end_y)
    if not start_node or not end_node then return nil end
    if not start_node.walkable or not end_node.walkable then return nil end
    log.info("start_node: %s, end_node: %s", start_node.id, end_node.id)
    -- 使用最小堆优化open_set
    local open_heap = MinHeap.new(function(a, b)
        return a.f_score < b.f_score
    end)
    local in_open_set = {}
    local closed_set = {}
    local came_from = {}
    local g_score = {[start_node.id] = 0}
    
    open_heap:push({
        id = start_node.id,
        f_score = self:heuristic(start_node, end_node, unit_type)
    })
    in_open_set[start_node.id] = true
    
    while not open_heap:empty() do
        local current = open_heap:pop()
        local current_id = current.id
        local current_node = self.nodes[current_id]
        in_open_set[current_id] = nil
        
        if current_id == end_node.id then
            return self:reconstruct_path(came_from, end_node, start_x, start_y, end_x, end_y, path_smooth)
        end
        
        closed_set[current_id] = true
        
        -- 遍历八个方向
        for dir = 1, 8 do
            if current_node.connections[dir] then
                local next_row = current_node.row + DIRECTIONS[dir][1]
                local next_col = current_node.col + DIRECTIONS[dir][2]
                local next_node = self.grid[next_row] and self.grid[next_row][next_col]
                
                if next_node and not closed_set[next_node.id] and next_node.walkable then
                    -- 检查转向角度约束
                    if not max_turn_angle or self:check_turn_angle(came_from[current_id], current_id, next_node.id, max_turn_angle) then
                        local cost = self:calc_move_cost(current_node, next_node, unit_type)
                        local tentative_g_score = g_score[current_id] + cost
                        
                        if not g_score[next_node.id] or tentative_g_score < g_score[next_node.id] then
                            came_from[next_node.id] = current_id
                            g_score[next_node.id] = tentative_g_score
                            local f_score = tentative_g_score + self:heuristic(next_node, end_node, unit_type)
                            
                            if not in_open_set[next_node.id] then
                                open_heap:push({id = next_node.id, f_score = f_score})
                                in_open_set[next_node.id] = true
                            else
                                open_heap:update_key(next_node.id, f_score)
                            end
                        end
                    end
                end
            end
        end
    end
    return nil
end

-- 检查转向角度是否满足约束
function NavMesh:check_turn_angle(prev_id, current_id, next_id, max_angle)
    if not prev_id then return true end
    
    local prev = self.nodes[prev_id]
    local current = self.nodes[current_id]
    local next_node = self.nodes[next_id]
    
    local angle = math.abs(self:calc_angle(
        prev.x - current.x,
        prev.y - current.y,
        next_node.x - current.x,
        next_node.y - current.y
    ))
    return angle <= max_angle
end

-- 计算两个向量之间的角度
function NavMesh:calc_angle(x1, y1, x2, y2)
    local dot = x1 * x2 + y1 * y2
    local det = x1 * y2 - y1 * x2
    return math.deg(math.atan(det, dot))
end

-- 优化的启发式函数
function NavMesh:heuristic(node1, node2, unit_type)
    local dx = math.abs(node2.x - node1.x)
    local dy = math.abs(node2.y - node1.y)
    local terrain_cost = self:get_terrain_cost(unit_type)
    
    -- 考虑地形因素的启发式估计
    local base_cost = math.sqrt(dx * dx + dy * dy)
    local terrain_factor = (terrain_cost[node1.terrain_type] + terrain_cost[node2.terrain_type]) / 2
    
    return base_cost * terrain_factor
end

-- 优化的动态障碍处理
function NavMesh:add_dynamic_obstacle(x, y, radius)
    local obstacle = {x = x, y = y, radius = radius}
    table.insert(self.dynamic_obstacles, obstacle)
    
    -- 计算影响范围
    local min_row = math.max(1, math.floor((y - radius) / self.cell_size) + 1)
    local max_row = math.min(self.rows, math.ceil((y + radius) / self.cell_size))
    local min_col = math.max(1, math.floor((x - radius) / self.cell_size) + 1)
    local max_col = math.min(self.cols, math.ceil((x + radius) / self.cell_size))
    
    -- 获取相关分区
    local start_p_row = math.ceil(min_row / self.partition_size)
    local end_p_row = math.ceil(max_row / self.partition_size)
    local start_p_col = math.ceil(min_col / self.partition_size)
    local end_p_col = math.ceil(max_col / self.partition_size)
    
    -- 更新分区中的节点
    for p_row = start_p_row, end_p_row do
        for p_col = start_p_col, end_p_col do
            local partition = self.partitions[p_row][p_col]
            for _, node in ipairs(partition) do
                if self:is_in_obstacle(node, x, y, radius) then
                    node.blocked_count = node.blocked_count + 1
                    if node.blocked_count == 1 then
                        node.walkable = false
                        -- 更新连接
                        self:update_node_connections(node.row, node.col)
                    end
                end
            end
        end
    end
end

-- 优化的连接更新
function NavMesh:update_node_connections(row, col)
    local node = self.grid[row][col]
    if not node then return end
    
    -- 清除现有连接
    node.connections = {}
    
    -- 如果节点不可通行，直接返回
    if not node.walkable then return end
    
    -- 检查八个方向
    for dir = 1, 8 do
        local dir_offset = DIRECTIONS[dir]
        local next_row = row + dir_offset[1]
        local next_col = col + dir_offset[2]
        
        if next_row >= 1 and next_row <= self.rows and 
           next_col >= 1 and next_col <= self.cols then
            local next_node = self.grid[next_row][next_col]
            
            if next_node and next_node.walkable then
                -- 对角线移动需要检查两侧是否可通行
                if dir % 2 == 0 then  -- 对角线方向
                    local prev_dir = (dir - 1 > 0) and dir - 1 or 8
                    local next_dir = (dir + 1 <= 8) and dir + 1 or 1
                    
                    local side1_row = row + DIRECTIONS[prev_dir][1]
                    local side1_col = col + DIRECTIONS[prev_dir][2]
                    local side2_row = row + DIRECTIONS[next_dir][1]
                    local side2_col = col + DIRECTIONS[next_dir][2]
                    
                    local side1_node = self.grid[side1_row] and self.grid[side1_row][side1_col]
                    local side2_node = self.grid[side2_row] and self.grid[side2_row][side2_col]
                    
                    if side1_node and side2_node and side1_node.walkable and side2_node.walkable then
                        node.connections[dir] = 1.414  -- √2
                    end
                else
                    node.connections[dir] = 1
                end
            end
        end
    end
end

-- 优化的路径平滑
function NavMesh:smooth_path(path, smooth_factor)
    if #path < 3 then return path end
    
    smooth_factor = smooth_factor or 0.5  -- 平滑因子
    local smoothed = {path[1]}  -- 保留起点
    
    -- 使用贝塞尔曲线平滑
    local i = 2
    while i < #path do
        local p0 = smoothed[#smoothed]
        local p1 = path[i]
        local p2 = path[i + 1]
        
        -- 检查直线可通行性
        if self:is_clear_line(p0.x, p0.y, p2.x, p2.y) then
            -- 可以直接连接，跳过中间点
            i = i + 1
        else
            -- 尝试平滑后的点
            local smooth_x = p1.x + smooth_factor * (p0.x + p2.x - 2 * p1.x)
            local smooth_y = p1.y + smooth_factor * (p0.y + p2.y - 2 * p1.y)
            
            -- 检查平滑后的路径是否可通行
            if self:is_clear_line(p0.x, p0.y, smooth_x, smooth_y) and
               self:is_clear_line(smooth_x, smooth_y, p2.x, p2.y) then
                -- 确保平滑点不会太靠近障碍物
                local node = self:get_node_at(smooth_x, smooth_y)
                if node and node.walkable then
                    table.insert(smoothed, {x = smooth_x, y = smooth_y})
                else
                    table.insert(smoothed, p1)
                end
            else
                table.insert(smoothed, p1)
            end
            i = i + 1
        end
    end
    
    -- 添加终点
    table.insert(smoothed, path[#path])
    
    -- 验证最终路径的可通行性
    for i = 1, #smoothed - 1 do
        if not self:is_clear_line(smoothed[i].x, smoothed[i].y, 
                                smoothed[i + 1].x, smoothed[i + 1].y) then
            -- 如果发现不可通行的段，返回原始路径
            log.warn("Smoothed path contains unwalkable segment, returning original path")
            return path
        end
    end
    
    return smoothed
end

-- 传送点处理
function NavMesh:handle_transport(node)
    if node.terrain_type == NavMesh.SPECIAL_TERRAIN.TRANSPORT then
        -- 在这里处理传送点逻辑
        -- 可以返回传送目标点或特殊移动代价
        return true
    end
    return false
end

function NavMesh:build_from_terrain()
    local node_id = 1
    -- 初始化网格
    for row = 1, self.rows do
        self.grid[row] = {}
        for col = 1, self.cols do
            local terrain_type = self.terrain:get_terrain_type(col, row)
            local node = {
                id = node_id,
                row = row,
                col = col,
                x = (col - 0.5) * self.cell_size,  -- 使用格子中心点作为坐标
                y = (row - 0.5) * self.cell_size,
                walkable = not NavMesh.BLOCKED_TERRAIN_TYPES[terrain_type],
                terrain_type = terrain_type,
                connections = {}  -- {dir_index => cost}
            }
            self.grid[row][col] = node
            self.nodes[node_id] = node
            node_id = node_id + 1
        end
    end
    
    -- 初始化每个节点的连接
    for row = 1, self.rows do
        for col = 1, self.cols do
            self:update_node_connections(row, col)
        end
    end
end

function NavMesh:get_neighbors(x, y)
    local neighbors = {}
    local directions = {
        {x = -1, y = 0},  -- 左
        {x = 1, y = 0},   -- 右
        {x = 0, y = -1},  -- 上
        {x = 0, y = 1},   -- 下
        {x = -1, y = -1}, -- 左上
        {x = 1, y = -1},  -- 右上
        {x = -1, y = 1},  -- 左下
        {x = 1, y = 1}    -- 右下
    }
    
    for _, dir in ipairs(directions) do
        local new_x = x + dir.x
        local new_y = y + dir.y
        
        -- 检查是否在地图范围内
        if new_x >= 1 and new_x <= self.width and 
           new_y >= 1 and new_y <= self.height then
            local node = self.grid[new_y][new_x]
            if node.walkable then
                -- 对角线移动时需要检查两个相邻格子是否可通行
                if dir.x ~= 0 and dir.y ~= 0 then
                    local node1 = self.grid[y][new_x]
                    local node2 = self.grid[new_y][x]
                    if node1.walkable or node2.walkable then
                        table.insert(neighbors, node)
                    end
                else
                    table.insert(neighbors, node)
                end
            end
        end
    end
    
    return neighbors
end

function NavMesh:get_node(x, y)
    if x < 1 or x > self.width or y < 1 or y > self.height then
        return nil
    end
    return self.grid[y][x]
end

function NavMesh:get_distance(node1, node2)
    local dx = math.abs(node1.x - node2.x)
    local dy = math.abs(node1.y - node2.y)
    
    -- 使用对角线距离作为启发式函数
    -- 对角线移动的代价为1.4（根号2），直线移动的代价为1
    return math.max(dx, dy) + (math.sqrt(2) - 1) * math.min(dx, dy)
end

-- 简单的A*寻路接口
function NavMesh:find_path(start_x, start_y, end_x, end_y)
    return self:find_path_with_options(start_x, start_y, end_x, end_y, nil, {})
end

-- 检查指定位置是否可行走
function NavMesh:is_walkable(row, col)
    if row < 1 or row > self.rows or col < 1 or col > self.cols then
        return false
    end
    local node = self.grid[row][col]
    return node and node.walkable
end

-- 检查指定坐标是否可行走
function NavMesh:is_walkable_by_coord(x, y)
    local row = math.floor(y / self.cell_size) + 1
    local col = math.floor(x / self.cell_size) + 1
    return self:is_walkable(row, col)
end

-- 根据世界坐标获取节点
function NavMesh:get_node_at(x, y)
    -- 将世界坐标转换为网格坐标
    local col = math.floor(x / self.cell_size) + 1
    local row = math.floor(y / self.cell_size) + 1
    
    -- 检查是否在地图范围内
    if row < 1 or row > self.rows or col < 1 or col > self.cols then
        return nil
    end
    
    return self.grid[row][col]
end

-- 获取地形移动代价
function NavMesh:get_terrain_cost(unit_type)
    -- 如果指定了单位类型，并且该单位类型有特殊的地形代价设置
    if unit_type and self.unit_terrain_cost[unit_type] then
        return self.unit_terrain_cost[unit_type]
    end
    -- 否则返回默认地形代价
    return self.default_terrain_cost
end

-- 设置单位类型的特殊地形代价
function NavMesh:set_unit_terrain_cost(unit_type, terrain_costs)
    self.unit_terrain_cost[unit_type] = terrain_costs
end

-- 计算移动代价
function NavMesh:calc_move_cost(from_node, to_node, unit_type)
    local terrain_cost = self:get_terrain_cost(unit_type)
    -- 基础代价（直线移动为1，对角线移动为1.414）
    local base_cost = from_node.connections[self:get_direction(from_node, to_node)]
    -- 目标格子的地形代价
    local terrain_factor = terrain_cost[to_node.terrain_type] or 1
    return base_cost * terrain_factor
end

-- 获取两个节点之间的方向索引
function NavMesh:get_direction(from_node, to_node)
    local dx = to_node.col - from_node.col
    local dy = to_node.row - from_node.row
    
    -- 将差值标准化为-1、0、1
    dx = dx ~= 0 and dx / math.abs(dx) or 0
    dy = dy ~= 0 and dy / math.abs(dy) or 0
    
    -- 遍历方向数组找到匹配的方向
    for dir = 1, 8 do
        if DIRECTIONS[dir][1] == dy and DIRECTIONS[dir][2] == dx then
            return dir
        end
    end
    
    return 1  -- 默认返回上方向（理论上不应该到达这里）
end

-- 重建路径
function NavMesh:reconstruct_path(came_from, end_node, start_x, start_y, end_x, end_y, should_smooth)
    -- 从终点回溯到起点构建路径
    local path = {}
    local current = end_node
    
    -- 添加终点（使用传入的精确坐标）
    table.insert(path, 1, {x = end_x, y = end_y})
    
    -- 回溯构建路径
    while current do
        local parent_id = came_from[current.id]
        if not parent_id then break end
        
        local parent = self.nodes[parent_id]
        if not parent then break end
        
        -- 添加路径点（使用节点中心点坐标）
        table.insert(path, 1, {x = current.x, y = current.y})
        current = parent
    end
    
    -- 添加起点（使用传入的精确坐标）
    table.insert(path, 1, {x = start_x, y = start_y})
    
    -- 如果需要平滑处理
    if should_smooth then
        return self:smooth_path(path)
    end
    
    return path
end

-- 检查两点之间是否可以直接连接
function NavMesh:is_clear_line(x1, y1, x2, y2)
    -- 使用Bresenham算法检查路径上的所有格子是否可通行
    local dx = math.abs(x2 - x1)
    local dy = math.abs(y2 - y1)
    local x = x1
    local y = y1
    local n = 1 + dx + dy
    local x_inc = (x2 > x1) and 1 or -1
    local y_inc = (y2 > y1) and 1 or -1
    local error = dx - dy
    dx = dx * 2
    dy = dy * 2

    -- 检查起点和终点
    local start_node = self:get_node_at(x1, y1)
    local end_node = self:get_node_at(x2, y2)
    if not start_node or not end_node or 
       not start_node.walkable or not end_node.walkable then
        return false
    end

    -- 使用更密集的采样点来检查路径
    local steps = math.max(math.abs(x2 - x1), math.abs(y2 - y1)) * 2
    for i = 1, steps do
        local t = i / steps
        local check_x = x1 + (x2 - x1) * t
        local check_y = y1 + (y2 - y1) * t
        
        local node = self:get_node_at(check_x, check_y)
        if not node or not node.walkable then
            return false
        end
    end
    
    return true
end

return NavMesh 