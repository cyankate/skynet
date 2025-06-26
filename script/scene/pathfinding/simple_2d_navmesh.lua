local class = require "utils.class"
local log = require "log"
local MinHeap = require "utils.min_heap"

-- 2D网格节点
local GridNode = class("GridNode")

function GridNode:ctor(x, y, walkable, terrain_type)
    self.x = x
    self.y = y
    self.walkable = walkable or true
    self.terrain_type = terrain_type or 1  -- 1=平地, 2=水域, 3=山地, 4=障碍物
    self.g = 0  -- 从起点到当前节点的代价
    self.h = 0  -- 从当前节点到终点的预估代价
    self.f = 0  -- f = g + h
    self.parent = nil
    self.neighbors = {}  -- 相邻节点
    self.id = string.format("%d_%d", x, y)  -- 为MinHeap提供唯一ID
end

function GridNode:get_f()
    return self.g + self.h
end

-- 简单2D网格导航系统
local Simple2DNavMesh = class("Simple2DNavMesh")

-- 地形移动代价
Simple2DNavMesh.TERRAIN_COST = {
    [1] = 1.0,    -- 平地
    [2] = 2.0,    -- 水域
    [3] = 3.0,    -- 山地
    [4] = 999.0,  -- 障碍物（不可通行）
    [5] = 0.8,    -- 安全区
    [6] = 0.5,    -- 传送点
}

-- 不可通行地形
Simple2DNavMesh.BLOCKED_TERRAIN = {
    [4] = true,   -- 障碍物
}

function Simple2DNavMesh:ctor(width, height, grid_size)
    self.width = width
    self.height = height
    self.grid_size = grid_size or 1
    self.grid_width = math.ceil(width / grid_size)
    self.grid_height = math.ceil(height / grid_size)
    
    -- 网格数据
    self.grid = {}
    self.dynamic_obstacles = {}
    self.path_cache = {}
    
    -- 初始化网格
    self:init_grid()
    
    log.info("Simple2DNavMesh initialized: %dx%d grid, cell_size: %d", 
             self.grid_width, self.grid_height, self.grid_size)
end

-- 初始化网格
function Simple2DNavMesh:init_grid()
    for y = 1, self.grid_height do
        self.grid[y] = {}
        for x = 1, self.grid_width do
            self.grid[y][x] = GridNode.new(x, y, true, 1)
        end
    end
    
    -- 建立邻居关系
    self:build_neighbors()
end

-- 建立邻居关系
function Simple2DNavMesh:build_neighbors()
    for y = 1, self.grid_height do
        for x = 1, self.grid_width do
            local node = self.grid[y][x]
            node.neighbors = {}
            
            -- 8方向邻居
            local directions = {
                {-1, -1}, {0, -1}, {1, -1},
                {-1, 0},           {1, 0},
                {-1, 1},  {0, 1},  {1, 1}
            }
            
            for _, dir in ipairs(directions) do
                local nx, ny = x + dir[1], y + dir[2]
                if nx >= 1 and nx <= self.grid_width and ny >= 1 and ny <= self.grid_height then
                    table.insert(node.neighbors, self.grid[ny][nx])
                end
            end
        end
    end
end

-- 世界坐标转网格坐标
function Simple2DNavMesh:world_to_grid(world_x, world_y)
    local grid_x = math.floor(world_x / self.grid_size) + 1
    local grid_y = math.floor(world_y / self.grid_size) + 1
    return grid_x, grid_y
end

-- 网格坐标转世界坐标
function Simple2DNavMesh:grid_to_world(grid_x, grid_y)
    local world_x = (grid_x - 1) * self.grid_size + self.grid_size / 2
    local world_y = (grid_y - 1) * self.grid_size + self.grid_size / 2
    return world_x, world_y
end

-- 获取网格节点
function Simple2DNavMesh:get_node(world_x, world_y)
    local grid_x, grid_y = self:world_to_grid(world_x, world_y)
    if grid_x >= 1 and grid_x <= self.grid_width and grid_y >= 1 and grid_y <= self.grid_height then
        return self.grid[grid_y][grid_x]
    end
    return nil
end

-- 设置地形类型
function Simple2DNavMesh:set_terrain(world_x, world_y, terrain_type)
    local node = self:get_node(world_x, world_y)
    if node then
        node.terrain_type = terrain_type
        node.walkable = not Simple2DNavMesh.BLOCKED_TERRAIN[terrain_type]
    end
end

-- 批量设置地形
function Simple2DNavMesh:set_terrain_batch(terrain_data)
    for _, data in ipairs(terrain_data) do
        self:set_terrain(data.x, data.y, data.terrain_type)
    end
end

-- 添加动态障碍物
function Simple2DNavMesh:add_obstacle(world_x, world_y, radius)
    local obstacle = {
        x = world_x,
        y = world_y,
        radius = radius,
        affected_nodes = {}  -- 记录受影响的节点
    }
    table.insert(self.dynamic_obstacles, obstacle)
    
    -- 只更新受影响的网格节点
    self:update_obstacle_affected_nodes(obstacle)
end

-- 移除动态障碍物
function Simple2DNavMesh:remove_obstacle(world_x, world_y, radius)
    for i = #self.dynamic_obstacles, 1, -1 do
        local obstacle = self.dynamic_obstacles[i]
        if obstacle.x == world_x and obstacle.y == world_y and obstacle.radius == radius then
            -- 恢复受影响的节点
            self:restore_obstacle_affected_nodes(obstacle)
            table.remove(self.dynamic_obstacles, i)
            break
        end
    end
end

-- 检查障碍物是否与格子重叠
function Simple2DNavMesh:check_obstacle_grid_overlap(obstacle_x, obstacle_y, obstacle_radius, grid_x, grid_y)
    local world_x, world_y = self:grid_to_world(grid_x, grid_y)
    
    -- 计算格子边界
    local grid_min_x = world_x - self.grid_size / 2
    local grid_max_x = world_x + self.grid_size / 2
    local grid_min_y = world_y - self.grid_size / 2
    local grid_max_y = world_y + self.grid_size / 2
    
    -- 计算障碍物边界
    local obstacle_min_x = obstacle_x - obstacle_radius
    local obstacle_max_x = obstacle_x + obstacle_radius
    local obstacle_min_y = obstacle_y - obstacle_radius
    local obstacle_max_y = obstacle_y + obstacle_radius
    
    -- 检查是否有重叠
    if obstacle_max_x < grid_min_x or obstacle_min_x > grid_max_x or
       obstacle_max_y < grid_min_y or obstacle_min_y > grid_max_y then
        return false  -- 没有重叠
    end
    
    -- 如果有重叠，进一步检查障碍物中心到格子最近点的距离
    local closest_x = math.max(grid_min_x, math.min(obstacle_x, grid_max_x))
    local closest_y = math.max(grid_min_y, math.min(obstacle_y, grid_max_y))
    
    local dx = obstacle_x - closest_x
    local dy = obstacle_y - closest_y
    local distance = math.sqrt(dx * dx + dy * dy)
    
    return distance <= obstacle_radius
end

-- 更新单个障碍物影响的节点
function Simple2DNavMesh:update_obstacle_affected_nodes(obstacle)
    -- 计算障碍物影响的网格范围（扩大范围确保覆盖所有可能受影响的格子）
    local min_grid_x, min_grid_y = self:world_to_grid(obstacle.x - obstacle.radius - self.grid_size/2, obstacle.y - obstacle.radius - self.grid_size/2)
    local max_grid_x, max_grid_y = self:world_to_grid(obstacle.x + obstacle.radius + self.grid_size/2, obstacle.y + obstacle.radius + self.grid_size/2)
    
    -- 限制在网格范围内
    min_grid_x = math.max(1, min_grid_x)
    min_grid_y = math.max(1, min_grid_y)
    max_grid_x = math.min(self.grid_width, max_grid_x)
    max_grid_y = math.min(self.grid_height, max_grid_y)
    
    -- 只遍历受影响的网格范围
    for y = min_grid_y, max_grid_y do
        for x = min_grid_x, max_grid_x do
            local node = self.grid[y][x]
            
            -- 使用改进的重叠检测
            if self:check_obstacle_grid_overlap(obstacle.x, obstacle.y, obstacle.radius, x, y) then
                -- 初始化节点的障碍物影响记录
                if not node.obstacle_effects then
                    node.obstacle_effects = {}
                    node.original_walkable = node.walkable
                end
                
                -- 记录这个障碍物的影响
                node.obstacle_effects[obstacle] = true
                
                -- 设置节点为不可行走
                node.walkable = false
                
                -- 记录受影响的节点
                table.insert(obstacle.affected_nodes, {x = x, y = y, node = node})
            end
        end
    end
    
    -- 清除路径缓存（因为地形发生了变化）
    self:clear_path_cache()
end

-- 恢复障碍物影响的节点
function Simple2DNavMesh:restore_obstacle_affected_nodes(obstacle)
    -- 恢复所有受影响的节点
    for _, affected in ipairs(obstacle.affected_nodes) do
        local node = affected.node
        
        -- 移除这个障碍物的影响记录
        if node.obstacle_effects then
            node.obstacle_effects[obstacle] = nil
            
            -- 检查是否还有其他障碍物影响这个节点
            local has_other_obstacles = false
            for _ in pairs(node.obstacle_effects) do
                has_other_obstacles = true
                break
            end
            
            if not has_other_obstacles then
                -- 没有其他障碍物影响，恢复原始状态
                if node.original_walkable ~= nil then
                    node.walkable = node.original_walkable
                    node.original_walkable = nil
                    node.obstacle_effects = nil
                else
                    -- 如果没有原始状态记录，根据地形类型设置
                    node.walkable = not Simple2DNavMesh.BLOCKED_TERRAIN[node.terrain_type]
                    node.obstacle_effects = nil
                end
            end
            -- 如果还有其他障碍物影响，保持不可行走状态
        end
    end
    
    -- 清除路径缓存
    self:clear_path_cache()
end

-- 统计节点上障碍物影响的数量
function Simple2DNavMesh:count_obstacle_effects(node)
    if not node.obstacle_effects then
        return 0
    end
    
    local count = 0
    for _ in pairs(node.obstacle_effects) do
        count = count + 1
    end
    return count
end

-- 清除路径缓存
function Simple2DNavMesh:clear_path_cache()
    self.path_cache = {}
end

-- 清除缓存（别名方法，保持API一致性）
function Simple2DNavMesh:clear_cache()
    self:clear_path_cache()
end

-- 更新所有障碍物影响的节点（用于初始化或重置）
function Simple2DNavMesh:update_all_obstacle_affected_nodes()
    -- 重置所有节点的阻塞状态
    for y = 1, self.grid_height do
        for x = 1, self.grid_width do
            local node = self.grid[y][x]
            node.walkable = not Simple2DNavMesh.BLOCKED_TERRAIN[node.terrain_type]
            node.original_walkable = nil
            node.obstacle_effects = nil
        end
    end
    
    -- 重新应用所有动态障碍物
    for _, obstacle in ipairs(self.dynamic_obstacles) do
        obstacle.affected_nodes = {}  -- 清空之前的记录
        self:update_obstacle_affected_nodes(obstacle)
    end
end

-- 寻路（A*算法）
function Simple2DNavMesh:find_path(start_x, start_y, end_x, end_y, options)
    options = options or {}
    
    -- 检查缓存
    local cache_key = string.format("%.1f_%.1f_%.1f_%.1f", start_x, start_y, end_x, end_y)
    if self.path_cache[cache_key] then
        return self.path_cache[cache_key]
    end
    
    local start_node = self:get_node(start_x, start_y)
    local end_node = self:get_node(end_x, end_y)
    
    if not start_node or not end_node then
        return nil, "起点或终点超出范围"
    end
    
    if not start_node.walkable or not end_node.walkable then
        return nil, "起点或终点不可通行"
    end
    
    -- A*算法实现
    local open_set = MinHeap.new(function(a, b) 
        return a.f < b.f 
    end)
    local closed_set = {}
    local came_from = {}
    local max_iterations = self.grid_width * self.grid_height  -- 最大迭代次数
    local iterations = 0
    
    -- 重置所有节点的状态
    for y = 1, self.grid_height do
        for x = 1, self.grid_width do
            local node = self.grid[y][x]
            node.g = math.huge
            node.h = 0
            node.f = math.huge
            node.parent = nil
        end
    end
    
    -- 初始化起点
    start_node.g = 0
    start_node.h = self:heuristic(start_node, end_node)
    start_node.f = start_node:get_f()
    open_set:push(start_node)
    
    while not open_set:empty() and iterations < max_iterations do
        iterations = iterations + 1
        
        -- 找到f值最小的节点
        local current = open_set:pop()
        closed_set[current] = true  -- 使用哈希表提高查找效率
        
        -- 到达终点
        if current == end_node then
            local path = self:reconstruct_path(came_from, end_node, start_x, start_y, end_x, end_y)
            
            -- 路径平滑
            if options.smooth then
                path = self:smooth_path(path, options.smooth_factor or 0.3)
            end
            
            -- 缓存结果
            self.path_cache[cache_key] = path
            return path
        end
        
        -- 检查邻居节点
        for _, neighbor in ipairs(current.neighbors) do
            if not neighbor.walkable or closed_set[neighbor] then
                goto continue
            end
            
            -- 计算新代价
            local tentative_g = current.g + self:calc_move_cost(current, neighbor)
            
            -- 检查是否已在开放列表中
            local in_open_set = false
            for _, open_node in ipairs(open_set.items) do
                if open_node == neighbor then
                    in_open_set = true
                    break
                end
            end
            
            if in_open_set then
                -- 节点已在开放列表中，检查是否需要更新
                if tentative_g < neighbor.g then
                    neighbor.g = tentative_g
                    neighbor.parent = current
                    neighbor.f = neighbor:get_f()
                    open_set:update_key(neighbor.id, neighbor.f)
                end
            else
                -- 新节点，添加到开放列表
                neighbor.g = tentative_g
                neighbor.h = self:heuristic(neighbor, end_node)
                neighbor.parent = current
                neighbor.f = neighbor:get_f()
                open_set:push(neighbor)
            end
            
            ::continue::
        end
    end
    
    -- 没找到路径
    if iterations >= max_iterations then
        return nil, "寻路超时，可能陷入死循环"
    else
        return nil, "找不到路径"
    end
end

-- 启发式函数（曼哈顿距离）
function Simple2DNavMesh:heuristic(node1, node2)
    local dx = math.abs(node2.x - node1.x)
    local dy = math.abs(node2.y - node1.y)
    return (dx + dy) * self.grid_size
end

-- 计算移动代价
function Simple2DNavMesh:calc_move_cost(from_node, to_node)
    local dx = to_node.x - from_node.x
    local dy = to_node.y - from_node.y
    local distance = math.sqrt(dx * dx + dy * dy) * self.grid_size
    
    -- 地形代价
    local terrain_cost = Simple2DNavMesh.TERRAIN_COST[to_node.terrain_type] or 1.0
    
    return distance * terrain_cost
end

-- 重构路径
function Simple2DNavMesh:reconstruct_path(came_from, end_node, start_x, start_y, end_x, end_y)
    local path = {}
    local current = end_node
    
    while current do
        local world_x, world_y = self:grid_to_world(current.x, current.y)
        table.insert(path, 1, {x = world_x, y = world_y})
        current = current.parent
    end
    
    -- 添加精确的起点和终点
    if #path > 0 then
        path[1] = {x = start_x, y = start_y}
        path[#path] = {x = end_x, y = end_y}
    end
    
    return path
end

-- 路径平滑
function Simple2DNavMesh:smooth_path(path, smooth_factor)
    if not path or #path < 3 then
        return path
    end
    
    smooth_factor = smooth_factor or 0.3
    local smoothed_path = {path[1]}
    
    for i = 2, #path - 1 do
        local prev = path[i - 1]
        local current = path[i]
        local next = path[i + 1]
        
        -- 检查直线是否可行
        if self:is_line_walkable(prev.x, prev.y, next.x, next.y) then
            -- 可以直线通过，跳过中间点
        else
            -- 需要保留中间点，但可以稍微平滑
            local smooth_x = current.x * (1 - smooth_factor) + (prev.x + next.x) * smooth_factor * 0.5
            local smooth_y = current.y * (1 - smooth_factor) + (prev.y + next.y) * smooth_factor * 0.5
            table.insert(smoothed_path, {x = smooth_x, y = smooth_y})
        end
    end
    
    table.insert(smoothed_path, path[#path])
    return smoothed_path
end

-- 检查直线是否可行
function Simple2DNavMesh:is_line_walkable(x1, y1, x2, y2)
    local dx = x2 - x1
    local dy = y2 - y1
    local distance = math.sqrt(dx * dx + dy * dy)
    local steps = math.ceil(distance / (self.grid_size * 0.5))
    if steps == 0 then
        local node = self:get_node(x1, y1)
        return node and node.walkable
    end
    for i = 0, steps do
        local t = i / steps
        local x = x1 + dx * t
        local y = y1 + dy * t
        local node = self:get_node(x, y)
        if not node or not node.walkable then
            return false
        end
    end
    
    return true
end

-- 批量寻路
function Simple2DNavMesh:find_paths_batch(requests)
    local results = {}
    
    for i, request in ipairs(requests) do
        local path, error = self:find_path(
            request.start_x, request.start_y,
            request.end_x, request.end_y,
            request.options
        )
        
        results[i] = {
            path = path,
            error = error,
            request_id = request.id or i
        }
    end
    
    return results
end

-- 获取网格统计信息
function Simple2DNavMesh:get_stats()
    local total_nodes = self.grid_width * self.grid_height
    local walkable_nodes = 0
    local terrain_stats = {}
    
    for y = 1, self.grid_height do
        for x = 1, self.grid_width do
            local node = self.grid[y][x]
            if node.walkable then
                walkable_nodes = walkable_nodes + 1
            end
            
            terrain_stats[node.terrain_type] = (terrain_stats[node.terrain_type] or 0) + 1
        end
    end
    
    return {
        grid_width = self.grid_width,
        grid_height = self.grid_height,
        total_nodes = total_nodes,
        walkable_nodes = walkable_nodes,
        walkable_ratio = walkable_nodes / total_nodes,
        terrain_distribution = terrain_stats,
        dynamic_obstacles = #self.dynamic_obstacles,
        cache_size = 0  -- 可以添加缓存大小统计
    }
end

-- 导出网格数据（用于调试）
function Simple2DNavMesh:export_grid_data()
    local data = {
        width = self.grid_width,
        height = self.grid_height,
        grid_size = self.grid_size,
        nodes = {}
    }
    
    for y = 1, self.grid_height do
        data.nodes[y] = {}
        for x = 1, self.grid_width do
            local node = self.grid[y][x]
            data.nodes[y][x] = {
                walkable = node.walkable,
                terrain_type = node.terrain_type
            }
        end
    end
    
    return data
end

return Simple2DNavMesh 