local skynet = require "skynet"
local class = require "utils.class"
local MinHeap = require "utils.min_heap"
local log = require "log"
local RecastAPI = require "scene.pathfinding.recast"

-- 区域管理器 - 基于RecastNavigation的导航网格
local RegionManager = class("RegionManager")

function RegionManager:ctor(navmesh_id)
    self.navmesh_id = navmesh_id
    self.regions = {}
    self.region_size = 64  -- 每个区域包含的三角形数量
    self.region_connections = {}
    self.region_cache = {}  -- 区域寻路缓存
    
    -- 获取导航网格信息
    local navmesh_info = RecastAPI.get_navmesh_info(navmesh_id)
    if not navmesh_info then
        log.error("Failed to get navmesh info for ID: %d", navmesh_id)
        return
    end
    
    -- 计算区域数量（基于三角形数量）
    local total_triangles = navmesh_info.triangle_count or 1000  -- 默认值
    self.region_count = math.ceil(total_triangles / self.region_size)
    
    log.info("Creating region manager with %d regions for navmesh %d", self.region_count, navmesh_id)
    
    self:init_regions()
end

function RegionManager:init_regions()
    -- 获取导航网格的三角形信息
    local triangles = RecastAPI.get_navmesh_triangles(self.navmesh_id)
    if not triangles then
        log.error("Failed to get triangles for navmesh %d", self.navmesh_id)
        return
    end
    
    -- 创建区域
    local triangle_ids = {}
    for id, _ in pairs(triangles) do
        table.insert(triangle_ids, id)
    end
    table.sort(triangle_ids)
    
    for i = 1, self.region_count do
        local start_idx = (i-1) * self.region_size + 1
        local end_idx = math.min(i * self.region_size, #triangle_ids)
        
        self.regions[i] = {
            id = i,
            triangle_ids = {},
            border_triangles = {},  -- 边界三角形
            neighbors = {},         -- 相邻区域
            bounds = {              -- 区域边界
                min_x = math.huge, min_y = math.huge, min_z = math.huge,
                max_x = -math.huge, max_y = -math.huge, max_z = -math.huge
            }
        }
        
        -- 分配三角形到区域
        for j = start_idx, end_idx do
            if triangle_ids[j] then
                local triangle_id = triangle_ids[j]
                table.insert(self.regions[i].triangle_ids, triangle_id)
                
                -- 更新区域边界
                local triangle = triangles[triangle_id]
                if triangle then
                    for _, vertex in ipairs(triangle.vertices) do
                        self.regions[i].bounds.min_x = math.min(self.regions[i].bounds.min_x, vertex[1])
                        self.regions[i].bounds.min_y = math.min(self.regions[i].bounds.min_y, vertex[2])
                        self.regions[i].bounds.min_z = math.min(self.regions[i].bounds.min_z, vertex[3])
                        self.regions[i].bounds.max_x = math.max(self.regions[i].bounds.max_x, vertex[1])
                        self.regions[i].bounds.max_y = math.max(self.regions[i].bounds.max_y, vertex[2])
                        self.regions[i].bounds.max_z = math.max(self.regions[i].bounds.max_z, vertex[3])
                    end
                end
            end
        end
        
        log.debug("Created region %d with %d triangles", i, #self.regions[i].triangle_ids)
    end
    
    -- 计算区域间连接
    self:calculate_region_connections()
end

function RegionManager:calculate_region_connections()
    -- 遍历所有区域，找出相邻的区域
    for i, region1 in ipairs(self.regions) do
        for j, region2 in ipairs(self.regions) do
            if i ~= j then
                -- 检查区域是否相邻（边界重叠）
                if self:regions_adjacent(region1, region2) then
                    table.insert(region1.neighbors, j)
                    table.insert(region2.neighbors, j)
                    
                    local connection = {
                        region1 = i,
                        region2 = j,
                        shared_boundary = self:get_shared_boundary(region1, region2)
                    }
                    table.insert(self.region_connections, connection)
                end
            end
        end
    end
end

function RegionManager:regions_adjacent(region1, region2)
    -- 检查两个区域是否相邻（边界重叠）
    local bounds1 = region1.bounds
    local bounds2 = region2.bounds
    
    -- 检查X轴重叠
    local x_overlap = not (bounds1.max_x < bounds2.min_x or bounds2.max_x < bounds1.min_x)
    -- 检查Z轴重叠（Y轴是高度）
    local z_overlap = not (bounds1.max_z < bounds2.min_z or bounds2.max_z < bounds1.min_z)
    
    return x_overlap and z_overlap
end

function RegionManager:get_shared_boundary(region1, region2)
    local bounds1 = region1.bounds
    local bounds2 = region2.bounds
    
    return {
        min_x = math.max(bounds1.min_x, bounds2.min_x),
        max_x = math.min(bounds1.max_x, bounds2.max_x),
        min_z = math.max(bounds1.min_z, bounds2.min_z),
        max_z = math.min(bounds1.max_z, bounds2.max_z)
    }
end

-- 并行寻路管理器 - 基于RecastNavigation
local ParallelPathfinder = class("ParallelPathfinder")

function ParallelPathfinder:ctor(navmesh_id)
    self.navmesh_id = navmesh_id
    self.region_manager = RegionManager.new(navmesh_id)
    self.path_cache = {}  -- 路径缓存
    self.region_path_cache = {}  -- 区域路径缓存
end

function ParallelPathfinder:find_path(start_x, start_y, start_z, end_x, end_y, end_z, options)
    options = options or {}
    
    -- 1. 确定起点和终点所在区域
    local start_region = self:get_region(start_x, start_z)  -- 使用X和Z坐标
    local end_region = self:get_region(end_x, end_z)
    
    -- 检查区域是否有效
    if not start_region or not end_region then
        log.error("Invalid regions - start: %s, end: %s", start_region and start_region.id or "nil", 
                 end_region and end_region.id or "nil")
        return nil, "Invalid regions"
    end
    
    if start_region.id == end_region.id then
        -- 同一区域内寻路，直接使用RecastNavigation
        return self:find_path_in_region(start_x, start_y, start_z, end_x, end_y, end_z, options)
    end
    
    -- 2. 获取区域级别的路径
    local region_path = self:find_region_path(start_region, end_region)
    if not region_path then
        return nil, "No region path found"
    end
    
    -- 3. 并行处理每个区域内的寻路
    local path_segments = {}
    local tasks = {}
    
    for i = 1, #region_path - 1 do
        local current_region_id = region_path[i]
        local current_region = self.region_manager.regions[current_region_id]
        local next_region_id = region_path[i + 1]
        local next_region = self.region_manager.regions[next_region_id]
        local connection = self:get_region_connection(current_region.id, next_region.id)
        
        -- 计算连接点
        local connection_point = self:get_connection_point(connection)
        
        -- 创建寻路任务
        local task = {
            start_x = i == 1 and start_x or connection_point.x,
            start_y = i == 1 and start_y or connection_point.y,
            start_z = i == 1 and start_z or connection_point.z,
            end_x = i == #region_path - 1 and end_x or connection_point.x,
            end_y = i == #region_path - 1 and end_y or connection_point.y,
            end_z = i == #region_path - 1 and end_z or connection_point.z,
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
            local path = self:find_path_in_region(
                task.start_x, task.start_y, task.start_z,
                task.end_x, task.end_y, task.end_z, 
                task.options
            )
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
            log.error("Task %d failed to complete", i)
        end
    end
    
    return results
end

function ParallelPathfinder:merge_path_segments(segments)
    if #segments == 0 then return nil end
    
    local final_path = {}
    for i, segment in ipairs(segments) do
        if segment then
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
    end
    
    -- 路径平滑处理
    return self:smooth_path(final_path)
end

-- 缓存管理
function ParallelPathfinder:update_cache(key, path)
    self.path_cache[key] = {
        path = path,
        timestamp = skynet.now(),
        use_count = 0
    }
end

function ParallelPathfinder:get_cached_path(start_x, start_y, start_z, end_x, end_y, end_z)
    local key = string.format("%.2f_%.2f_%.2f_%.2f_%.2f_%.2f", 
                             start_x, start_y, start_z, end_x, end_y, end_z)
    local cache = self.path_cache[key]
    if cache and skynet.now() - cache.timestamp < 300 then  -- 5分钟内的缓存有效
        cache.use_count = cache.use_count + 1
        return cache.path
    end
    return nil
end

function ParallelPathfinder:find_path_in_region(start_x, start_y, start_z, end_x, end_y, end_z, options)
    -- 检查缓存
    local cached_path = self:get_cached_path(start_x, start_y, start_z, end_x, end_y, end_z)
    if cached_path then
        return cached_path
    end

    -- 使用RecastNavigation寻路
    local path = RecastAPI.find_path(self.navmesh_id, 
        {start_x, start_y, start_z}, 
        {end_x, end_y, end_z}, 
        options
    )
    
    -- 更新缓存
    if path then
        self:update_cache(string.format("%.2f_%.2f_%.2f_%.2f_%.2f_%.2f", 
                                       start_x, start_y, start_z, end_x, end_y, end_z), path)
    end
    
    return path
end

function ParallelPathfinder:get_region(x, z)
    -- 查找包含坐标的区域
    for _, region in ipairs(self.region_manager.regions) do
        local bounds = region.bounds
        if x >= bounds.min_x and x <= bounds.max_x and
           z >= bounds.min_z and z <= bounds.max_z then
            return region
        end
    end
    
    log.error("Cannot find region for position: x=%.2f, z=%.2f", x, z)
    return nil
end

function ParallelPathfinder:get_connection_point(connection)
    if not connection or not connection.shared_boundary then
        return {x = 0, y = 0, z = 0}
    end
    
    local boundary = connection.shared_boundary
    return {
        x = (boundary.min_x + boundary.max_x) / 2,
        y = 0,  -- 默认高度
        z = (boundary.min_z + boundary.max_z) / 2
    }
end

-- 区域路径查找
function ParallelPathfinder:find_region_path(start_region, end_region)
    if not start_region or not end_region then return nil end
    if start_region.id == end_region.id then
        return {start_region.id}
    end
    
    -- 检查缓存
    local cache_key = string.format("%d_%d", start_region.id, end_region.id)
    if self.region_path_cache[cache_key] then
        return self.region_path_cache[cache_key]
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
            local path = self:reconstruct_region_sequence(came_from, start_region.id, end_region.id)
            -- 缓存结果
            self.region_path_cache[cache_key] = path
            return path
        end
        
        closed_set[current_id] = true
        
        -- 遍历相邻区域
        local current_region = self.region_manager.regions[current_id]
        for _, neighbor_id in ipairs(current_region.neighbors) do
            if not closed_set[neighbor_id] then
                local neighbor = self.region_manager.regions[neighbor_id]
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

-- 估算两个区域间的距离
function ParallelPathfinder:estimate_region_distance(region1, region2)
    -- 使用区域中心点的距离
    local center1_x, center1_z = self:get_region_center(region1)
    local center2_x, center2_z = self:get_region_center(region2)
    
    local dx = center1_x - center2_x
    local dz = center1_z - center2_z
    return math.sqrt(dx * dx + dz * dz)
end

-- 获取区域中心点
function ParallelPathfinder:get_region_center(region)
    local bounds = region.bounds
    return (bounds.min_x + bounds.max_x) / 2, (bounds.min_z + bounds.max_z) / 2
end

-- 获取连接的代价
function ParallelPathfinder:get_connection_cost(connection)
    -- 基础代价为1，可以根据连接边界大小调整
    local boundary = connection.shared_boundary
    if boundary then
        local width = boundary.max_x - boundary.min_x
        local depth = boundary.max_z - boundary.min_z
        local area = width * depth
        return 1 / (area + 1)  -- 面积越大，代价越小
    end
    return 1
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

-- 路径平滑处理
function ParallelPathfinder:smooth_path(path)
    if not path or #path < 3 then
        return path
    end
    
    local smoothed = {path[1]}
    
    for i = 2, #path - 1 do
        local prev = path[i - 1]
        local current = path[i]
        local next = path[i + 1]
        
        -- 检查转向角度
        local angle = self:calculate_turn_angle(prev, current, next)
        if angle > 45 then  -- 如果转向角度大于45度，保留该点
            table.insert(smoothed, current)
        end
    end
    
    table.insert(smoothed, path[#path])
    return smoothed
end

-- 计算转向角度
function ParallelPathfinder:calculate_turn_angle(prev, current, next)
    local v1x = current[1] - prev[1]
    local v1z = current[3] - prev[3]
    local v2x = next[1] - current[1]
    local v2z = next[3] - current[3]
    
    local dot = v1x * v2x + v1z * v2z
    local det = v1x * v2z - v1z * v2x
    local angle = math.abs(math.deg(math.atan(det, dot)))
    
    return angle
end

-- 批量寻路接口
function ParallelPathfinder:find_paths_batch(requests)
    local results = {}
    
    for i, request in ipairs(requests) do
        local path, error = self:find_path(
            request.start_x, request.start_y, request.start_z,
            request.end_x, request.end_y, request.end_z,
            request.options
        )
        
        results[i] = {
            path = path,
            error = error,
            request_id = request.id
        }
    end
    
    return results
end

-- 清理缓存
function ParallelPathfinder:clear_cache()
    self.path_cache = {}
    self.region_path_cache = {}
end

-- 获取缓存统计
function ParallelPathfinder:get_cache_stats()
    local path_cache_count = 0
    for _ in pairs(self.path_cache) do
        path_cache_count = path_cache_count + 1
    end
    
    local region_cache_count = 0
    for _ in pairs(self.region_path_cache) do
        region_cache_count = region_cache_count + 1
    end
    
    return {
        path_cache_count = path_cache_count,
        region_cache_count = region_cache_count,
        region_count = #self.region_manager.regions
    }
end

return ParallelPathfinder 