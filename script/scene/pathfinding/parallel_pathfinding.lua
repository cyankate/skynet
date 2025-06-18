local skynet = require "skynet"
local class = require "utils.class"
local MinHeap = require "utils.min_heap"

-- 区域管理器
local RegionManager = class("RegionManager")

function RegionManager:ctor(navmesh)
    self.navmesh = navmesh
    self.regions = {}
    self.region_size = 64  -- 每个区域的大小（格子数）
    self.region_connections = {}
    self.region_cache = {}  -- 区域寻路缓存
    
    -- 计算区域数量
    self.region_rows = math.ceil(navmesh.rows / self.region_size)
    self.region_cols = math.ceil(navmesh.cols / self.region_size)
    
    log.info("Creating region manager with size: %s x %s for navmesh size: %s x %s", self.region_rows, self.region_cols, navmesh.rows, navmesh.cols)
    
    self:init_regions()
end

function RegionManager:init_regions()
    -- 创建区域
    for i = 1, self.region_rows do
        self.regions[i] = {}
        for j = 1, self.region_cols do
            self.regions[i][j] = {
                id = i * 10000 + j,
                start_row = (i-1) * self.region_size + 1,
                start_col = (j-1) * self.region_size + 1,
                end_row = math.min(i * self.region_size, self.navmesh.rows),
                end_col = math.min(j * self.region_size, self.navmesh.cols),
                border_points = {},  -- 边界连接点
                neighbors = {}       -- 相邻区域
            }
            log.debug("Created region", i, j, "covering", 
                     self.regions[i][j].start_row, self.regions[i][j].end_row,
                     self.regions[i][j].start_col, self.regions[i][j].end_col)
        end
    end
    
    -- 计算区域间连接点
    self:calculate_region_connections()
end

function RegionManager:calculate_region_connections()
    -- 遍历所有区域边界，找出可通行的连接点
    for i, row in ipairs(self.regions) do
        for j, region in ipairs(row) do
            -- 检查上边界
            if i > 1 then
                self:find_border_points(region, self.regions[i-1][j], "up")
            end
            -- 检查右边界
            if j < #row then
                self:find_border_points(region, self.regions[i][j+1], "right")
            end
        end
    end
end

function RegionManager:find_border_points(region1, region2, direction)
    local points = {}
    if direction == "up" then
        -- 检查上边界的连接点
        local row = region1.start_row
        for col = region1.start_col, region1.end_col do
            if self:is_valid_connection(row, col) then
                table.insert(points, {row = row, col = col})
            end
        end
    elseif direction == "right" then
        -- 检查右边界的连接点
        local col = region1.end_col
        for row = region1.start_row, region1.end_row do
            if self:is_valid_connection(row, col) then
                table.insert(points, {row = row, col = col})
            end
        end
    end
    
    -- 记录连接点
    if #points > 0 then
        local connection = {
            points = points,
            region1 = region1.id,
            region2 = region2.id
        }
        table.insert(self.region_connections, connection)
        table.insert(region1.neighbors, region2.id)
        table.insert(region2.neighbors, region1.id)
    end
end

function RegionManager:is_valid_connection(row, col)
    -- 检查边界点是否可以作为连接点（必须是可行走的）
    -- 同时检查周围8个方向是否至少有一个可行走的格子
    if not self.navmesh:is_walkable(row, col) then
        return false
    end

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

    -- 检查周围8个方向
    for _, dir in ipairs(directions) do
        local next_row = row + dir[1]
        local next_col = col + dir[2]
        if self.navmesh:is_walkable(next_row, next_col) then
            return true
        end
    end

    return false
end

-- 并行寻路管理器
local ParallelPathfinder = class("ParallelPathfinder")

function ParallelPathfinder:ctor(navmesh)
    self.navmesh = navmesh
    self.region_manager = RegionManager.new(navmesh)
    self.path_cache = {}  -- 路径缓存
end

function ParallelPathfinder:find_path(start_x, start_y, end_x, end_y, options)
    -- 1. 确定起点和终点所在区域
    local start_region = self:get_region(start_x, start_y)
    local end_region = self:get_region(end_x, end_y)
    
    -- 检查区域是否有效
    if not start_region or not end_region then
        log.error("Invalid regions - start:", start_region, "end:", end_region)
        return nil
    end
    
    if start_region.id == end_region.id then
        -- 同一区域内寻路，直接使用A*
        return self:find_path_in_region(start_x, start_y, end_x, end_y, options)
    end
    
    -- 2. 获取区域级别的路径
    local region_path = self:find_region_path(start_region, end_region)
    if not region_path then
        return nil
    end
    
    -- 3. 并行处理每个区域内的寻路
    local path_segments = {}
    local tasks = {}
    
    for i = 1, #region_path - 1 do
        local current_region_id = region_path[i]
        local current_row = math.floor(current_region_id / 10000)
        local current_col = current_region_id % 10000
        local current_region = self.region_manager.regions[current_row][current_col]
        local next_region_id = region_path[i + 1]
        local next_row = math.floor(next_region_id / 10000)
        local next_col = next_region_id % 10000
        local next_region = self.region_manager.regions[next_row][next_col]
        local connection = self:get_region_connection(current_region.id, next_region.id)
        -- 创建寻路任务
        local task = {
            start_x = i == 1 and start_x or connection.points[1].x,
            start_y = i == 1 and start_y or connection.points[1].y,
            end_x = i == #region_path - 1 and end_x or connection.points[1].x,
            end_y = i == #region_path - 1 and end_y or connection.points[1].y,
            region = current_region,
            options = options
        }
        table.insert(tasks, task)
    end
    
    -- 4. 并行执行寻路任务
    local results = self:execute_parallel_tasks(tasks)
    
    -- 5. 合并路径段
    return self:merge_path_segments(results)
end

function ParallelPathfinder:execute_parallel_tasks(tasks)
    local results = {}
    local wait_count = #tasks
    
    local co = coroutine.running()
    -- 分配任务给工作线程
    for i, task in ipairs(tasks) do
        skynet.fork(function()
            -- 执行区域内寻路
            local path = self:find_path_in_region(task.start_x, task.start_y, task.end_x, task.end_y, task.options)
            results[i] = path
            -- 更新计数并检查是否所有任务都完成
            wait_count = wait_count - 1
            if wait_count == 0 then
                skynet.wakeup(co)
            end
        end)
    end
    -- 如果还有未完成的任务，等待它们完成
    if wait_count > 0 then
        skynet.wait()
    end
    -- 检查结果的完整性
    for i = 1, #tasks do
        if results[i] == nil then
            skynet.error("Task " .. i .. " failed to complete")
        end
    end
    
    return results
end

function ParallelPathfinder:merge_path_segments(segments)
    if #segments == 0 then return nil end
    
    local final_path = {}
    for i, segment in ipairs(segments) do
        if i == 1 then
            -- 第一段路径全部添加
            for _, point in ipairs(segment) do
                table.insert(final_path, point)
            end
        else
            -- 后续路径段去除第一个点（避免重复）
            for j = 2, #segment do
                table.insert(final_path, segment[j])
            end
        end
    end
    
    -- 路径平滑处理
    return self.navmesh:smooth_path(final_path)
end

-- 缓存管理
function ParallelPathfinder:update_cache(key, path)
    self.path_cache[key] = {
        path = path,
        timestamp = skynet.now(),
        use_count = 0
    }
end

function ParallelPathfinder:get_cached_path(start_x, start_y, end_x, end_y)
    if not start_x or not start_y or not end_x or not end_y then
        log.error("Invalid start_x: %s, start_y: %s, end_x: %s, end_y: %s", start_x, start_y, end_x, end_y)
    end
    local key = string.format("%d_%d_%d_%d", start_x, start_y, end_x, end_y)
    local cache = self.path_cache[key]
    if cache and skynet.now() - cache.timestamp < 300 then  -- 5分钟内的缓存有效
        cache.use_count = cache.use_count + 1
        return cache.path
    end
    return nil
end

function ParallelPathfinder:find_path_in_region(start_x, start_y, end_x, end_y, options)
    -- 检查缓存
    local cached_path = self:get_cached_path(start_x, start_y, end_x, end_y)
    if cached_path then
        return cached_path
    end

    -- 获取区域信息
    local region = self:get_region(start_x, start_y)
    if not region then return nil end

    -- 限制搜索范围在当前区域内
    options = options or {}
    options.search_bounds = {
        min_row = region.start_row,
        max_row = region.end_row,
        min_col = region.start_col,
        max_col = region.end_col
    }
    
    -- 使用NavMesh的寻路接口
    local path = self.navmesh:find_path_with_options(start_x, start_y, end_x, end_y, nil, options)
    if not path then
        log.error("Failed to find path in region: %s", region.id)
    end
    -- 更新缓存
    if path then
        self:update_cache(start_x, start_y, end_x, end_y, path)
    end
    return path
end

function ParallelPathfinder:get_region(x, y)
    -- 将世界坐标转换为网格坐标
    local row = math.floor(y / self.navmesh.cell_size) + 1
    local col = math.floor(x / self.navmesh.cell_size) + 1
    
    -- 计算区域坐标
    local region_row = math.ceil(row / self.region_manager.region_size)
    local region_col = math.ceil(col / self.region_manager.region_size)
    
    -- 检查区域是否存在
    if not self.region_manager.regions[region_row] then
        log.error("Invalid region row:", region_row, "for position:", x, y)
        return nil
    end
    
    local region = self.region_manager.regions[region_row][region_col]
    if not region then
        log.error("Invalid region col:", region_col, "for position:", x, y)
        return nil
    end
    
    return region
end

function ParallelPathfinder:check_turn_angle(prev_id, current_id, next_id, max_angle)
    if not prev_id then return true end
    
    local prev = self.navmesh.nodes[prev_id]
    local current = self.navmesh.nodes[current_id]
    local next_node = self.navmesh.nodes[next_id]
    
    -- 计算两个向量
    local v1x = current.x - prev.x
    local v1y = current.y - prev.y
    local v2x = next_node.x - current.x
    local v2y = next_node.y - current.y
    
    -- 计算夹角
    local dot = v1x * v2x + v1y * v2y
    local det = v1x * v2y - v1y * v2x
    local angle = math.abs(math.deg(math.atan(det, dot)))
    
    return angle <= max_angle
end

-- 区域路径查找
function ParallelPathfinder:find_region_path(start_region, end_region)
    if not start_region or not end_region then return nil end
    if start_region.id == end_region.id then
        return {start_region.id}
    end
    
    -- 使用A*在区域层级寻路
    local open_set = MinHeap.new(function(a, b)
        return a.f_score < b.f_score
    end)
    local in_open_set = {}
    local closed_set = {}
    local came_from = {}
    local g_score = {[start_region.id] = 0}
    
    open_set:push({
        id = start_region.id,
        f_score = self:estimate_region_distance(start_region, end_region)
    })
    in_open_set[start_region.id] = true
    
    while not open_set:empty() do
        local current = open_set:pop()
        local current_id = current.id
        in_open_set[current_id] = nil
        
        if current_id == end_region.id then
            return self:reconstruct_region_sequence(came_from, start_region.id, end_region.id)
        end
        
        closed_set[current_id] = true
        
        -- 遍历相邻区域
        for _, neighbor_id in ipairs(self:get_region_by_id(current_id).neighbors) do
            if not closed_set[neighbor_id] then
                local neighbor = self:get_region_by_id(neighbor_id)
                local connection = self:get_region_connection(current_id, neighbor_id)
                if connection then
                    local tentative_g_score = g_score[current_id] + self:get_connection_cost(connection)
                    
                    if not g_score[neighbor_id] or tentative_g_score < g_score[neighbor_id] then
                        came_from[neighbor_id] = current_id
                        g_score[neighbor_id] = tentative_g_score
                        local f_score = tentative_g_score + self:estimate_region_distance(neighbor, end_region)
                        
                        if not in_open_set[neighbor_id] then
                            open_set:push({id = neighbor_id, f_score = f_score})
                            in_open_set[neighbor_id] = true
                        else
                            open_set:update_key(neighbor_id, f_score)
                        end
                    end
                end
            end
        end
    end
    
    return nil
end

-- 获取区域间连接信息
function ParallelPathfinder:get_region_connection(region1_id, region2_id)
    for _, connection in ipairs(self.region_manager.region_connections) do
        if (connection.region1 == region1_id and connection.region2 == region2_id) or
           (connection.region1 == region2_id and connection.region2 == region1_id) then
            return connection
        end
    end
    return nil
end

-- 根据ID获取区域
function ParallelPathfinder:get_region_by_id(region_id)
    local row = math.floor(region_id / 10000)
    local col = region_id % 10000
    return self.region_manager.regions[row][col]
end

-- 估算两个区域间的距离
function ParallelPathfinder:estimate_region_distance(region1, region2)
    -- 使用区域中心点的曼哈顿距离
    local center1_x = (region1.start_col + region1.end_col) / 2
    local center1_y = (region1.start_row + region1.end_row) / 2
    local center2_x = (region2.start_col + region2.end_col) / 2
    local center2_y = (region2.start_row + region2.end_row) / 2
    
    return math.abs(center1_x - center2_x) + math.abs(center1_y - center2_y)
end

-- 获取连接的代价
function ParallelPathfinder:get_connection_cost(connection)
    -- 基础代价为连接点数量的倒数（连接点越多，代价越小）
    local base_cost = 1 / #connection.points
    
    -- 可以在这里添加其他因素，如：
    -- 1. 连接点的地形类型
    -- 2. 历史使用频率
    -- 3. 拥堵程度等
    
    return base_cost
end

-- 重建区域序列
function ParallelPathfinder:reconstruct_region_sequence(came_from, start_id, end_id)
    local path = {end_id}
    local current = end_id
    
    while current ~= start_id do
        current = came_from[current]
        if not current then return nil end
        table.insert(path, 1, current)
    end
    
    return path
end

return ParallelPathfinder 