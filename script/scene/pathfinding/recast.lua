local skynet = require "skynet"
local log = require "log"

-- 加载底层C库
local recast_c = require "recast"

local RecastAPI = {}

-- 配置默认值
RecastAPI.DEFAULT_CONFIG = {
    -- 网格参数
    cell_size = 0.3,           -- 网格单元大小
    cell_height = 0.2,         -- 网格单元高度
    walkable_slope_angle = 45, -- 可行走坡度
    walkable_height = 2.0,     -- 可行走高度
    walkable_radius = 0.6,     -- 可行走半径
    walkable_climb = 0.9,      -- 可行走攀爬高度
    
    -- 区域参数
    min_region_area = 8,       -- 最小区域面积
    merge_region_area = 20,    -- 合并区域面积
    
    -- 轮廓参数
    max_edge_len = 12,         -- 最大边长
    max_edge_error = 1.3,      -- 最大边误差
    
    -- 细节参数
    detail_sample_dist = 6,    -- 细节采样距离
    detail_sample_max_error = 1 -- 细节采样最大误差
}

-- 导航网格缓存
local navmesh_cache = {}
local path_cache = {}

-- 初始化系统
function RecastAPI.init()
    local result = recast_c.init()
    if result then
        log.info("RecastNavigation系统初始化成功")
        return true
    else
        log.error("RecastNavigation系统初始化失败")
        return false
    end
end

-- 从高度图创建导航网格
function RecastAPI.create_navmesh_from_heightmap(heightmap, config)
    config = config or {}
    
    -- 合并默认配置
    for k, v in pairs(RecastAPI.DEFAULT_CONFIG) do
        if config[k] == nil then
            config[k] = v
        end
    end
    
    -- 验证高度图数据
    if not heightmap or not heightmap.data or not heightmap.width or not heightmap.height then
        log.error("Invalid heightmap data")
        return nil, "Invalid heightmap data"
    end
    
    -- 预处理高度图
    local processed_data = preprocess_heightmap(heightmap)
    
    -- 创建导航网格
    local navmesh_id = recast_c.create_navmesh({
        heightmap = processed_data,
        width = heightmap.width,
        height = heightmap.height,
        terrain_data = heightmap.data,
        config = config
    })
    
    if navmesh_id then
        -- 缓存导航网格信息
        navmesh_cache[navmesh_id] = {
            id = navmesh_id,
            config = config,
            heightmap = heightmap,
            created_time = skynet.time()
        }
        
        log.info("创建导航网格成功，ID: %d, 尺寸: %dx%d", 
                navmesh_id, heightmap.width, heightmap.height)
        return navmesh_id
    else
        log.error("创建导航网格失败")
        return nil, "Failed to create navmesh"
    end
end

-- 从三角形网格创建导航网格
function RecastAPI.create_navmesh_from_triangles(triangles, config)
    config = config or {}
    
    -- 合并默认配置
    for k, v in pairs(RecastAPI.DEFAULT_CONFIG) do
        if config[k] == nil then
            config[k] = v
        end
    end
    
    -- 验证三角形数据
    if not triangles or #triangles == 0 then
        log.error("Invalid triangle data")
        return nil, "Invalid triangle data"
    end
    
    -- 预处理三角形数据
    local processed_triangles = preprocess_triangles(triangles)
    
    -- 创建导航网格
    local navmesh_id = recast_c.create_navmesh({
        triangles = processed_triangles,
        config = config
    })
    
    if navmesh_id then
        -- 缓存导航网格信息
        navmesh_cache[navmesh_id] = {
            id = navmesh_id,
            config = config,
            triangle_count = #triangles,
            created_time = skynet.time()
        }
        
        log.info("创建导航网格成功，ID: %d, 三角形数量: %d", 
                navmesh_id, #triangles)
        return navmesh_id
    else
        log.error("创建导航网格失败")
        return nil, "Failed to create navmesh"
    end
end

-- 寻路（带缓存）
function RecastAPI.find_path(navmesh_id, start_pos, end_pos, options)
    -- 参数验证
    if not navmesh_id or not start_pos or not end_pos then
        log.error("Invalid parameters for find_path")
        return nil, "Invalid parameters"
    end
    
    -- 检查导航网格是否存在
    if not navmesh_cache[navmesh_id] then
        log.error("Navmesh %d not found", navmesh_id)
        return nil, "Navmesh not found"
    end
    
    -- 生成缓存键
    local cache_key = generate_path_cache_key(navmesh_id, start_pos, end_pos, options)
    
    -- 检查缓存
    if path_cache[cache_key] then
        log.debug("Path found in cache")
        return path_cache[cache_key]
    end
    
    -- 执行寻路
    local path = recast_c.find_path(navmesh_id, start_pos[1], start_pos[2], start_pos[3], end_pos[1], end_pos[2], end_pos[3], options)
    
    if path then
        -- 后处理路径
        local processed_path = postprocess_path(path)
        
        -- 缓存结果
        path_cache[cache_key] = processed_path
        
        log.debug("寻路成功，路径点数: %d", #processed_path)
        return processed_path
    else
        log.warning("未找到路径: %s -> %s", table.concat(start_pos, ","), table.concat(end_pos, ","))
        return nil, "No path found"
    end
end

-- 批量寻路
function RecastAPI.find_paths_batch(requests)
    local results = {}
    
    for i, request in ipairs(requests) do
        local path, error = RecastAPI.find_path(
            request.navmesh_id,
            request.start_pos,
            request.end_pos,
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

-- 添加动态障碍物
function RecastAPI.add_obstacle(navmesh_id, obstacle_data)
    if not navmesh_cache[navmesh_id] then
        log.error("Navmesh %d not found", navmesh_id)
        return nil, "Navmesh not found"
    end
    
    local obstacle_id = recast_c.add_obstacle(navmesh_id, obstacle_data)
    
    if obstacle_id then
        log.info("添加动态障碍物成功，ID: %d", obstacle_id)
        return obstacle_id
    else
        log.error("添加动态障碍物失败")
        return nil, "Failed to add obstacle"
    end
end

-- 移除动态障碍物
function RecastAPI.remove_obstacle(navmesh_id, obstacle_id)
    if not navmesh_cache[navmesh_id] then
        log.error("Navmesh %d not found", navmesh_id)
        return false, "Navmesh not found"
    end
    
    local result = recast_c.remove_obstacle(navmesh_id, obstacle_id)
    
    if result then
        log.info("移除动态障碍物成功，ID: %d", obstacle_id)
        return true
    else
        log.error("移除动态障碍物失败，ID: %d", obstacle_id)
        return false, "Failed to remove obstacle"
    end
end

-- 获取导航网格信息
function RecastAPI.get_navmesh_info(navmesh_id)
    if not navmesh_cache[navmesh_id] then
        return nil, "Navmesh not found"
    end
    
    local info = navmesh_cache[navmesh_id]
    local c_info = recast_c.get_navmesh_info(navmesh_id)
    
    -- 合并信息
    if c_info then
        for k, v in pairs(c_info) do
            info[k] = v
        end
    end
    
    return info
end

-- 获取导航网格三角形信息
function RecastAPI.get_navmesh_triangles(navmesh_id)
    if not navmesh_cache[navmesh_id] then
        return nil, "Navmesh not found"
    end
    
    local triangles = recast_c.get_navmesh_triangles(navmesh_id)
    
    if triangles then
        log.debug("获取导航网格%d三角形信息成功，数量: %d", navmesh_id, #triangles)
        return triangles
    else
        log.error("获取导航网格%d三角形信息失败", navmesh_id)
        return nil, "Failed to get triangles"
    end
end

-- 销毁导航网格
function RecastAPI.destroy_navmesh(navmesh_id)
    if not navmesh_cache[navmesh_id] then
        log.warning("Navmesh %d not found", navmesh_id)
        return false
    end
    
    local result = recast_c.destroy_navmesh(navmesh_id)
    
    if result then
        -- 清理缓存
        navmesh_cache[navmesh_id] = nil
        clear_path_cache_for_navmesh(navmesh_id)
        
        log.info("销毁导航网格成功，ID: %d", navmesh_id)
        return true
    else
        log.error("销毁导航网格失败，ID: %d", navmesh_id)
        return false
    end
end

-- 清理所有资源
function RecastAPI.cleanup()
    -- 销毁所有导航网格
    for navmesh_id, _ in pairs(navmesh_cache) do
        recast_c.destroy_navmesh(navmesh_id)
    end
    
    -- 清理缓存
    navmesh_cache = {}
    path_cache = {}
    
    -- 清理C库资源
    recast_c.cleanup()
    
    log.info("RecastNavigation资源清理完成")
end

-- 工具函数

-- 预处理高度图
function preprocess_heightmap(heightmap)
    -- 这里可以添加高度图预处理逻辑
    -- 比如：平滑处理、噪声过滤、边界处理等
    return heightmap
end

-- 预处理三角形数据
function preprocess_triangles(triangles)
    -- 这里可以添加三角形预处理逻辑
    -- 比如：法向量计算、面积计算、邻居关系建立等
    return triangles
end

-- 生成路径缓存键
function generate_path_cache_key(navmesh_id, start_pos, end_pos, options)
    local key = string.format("%d_%.2f_%.2f_%.2f_%.2f_%.2f_%.2f",
        navmesh_id,
        start_pos[1], start_pos[2], start_pos[3],
        end_pos[1], end_pos[2], end_pos[3]
    )
    
    if options then
        key = key .. "_" .. tostring(options.max_path_length or 256)
    end
    
    return key
end

-- 后处理路径
function postprocess_path(path)
    -- 这里可以添加路径后处理逻辑
    -- 比如：路径平滑、简化、优化等
    return path
end

-- 清理指定导航网格的路径缓存
function clear_path_cache_for_navmesh(navmesh_id)
    local keys_to_remove = {}
    
    for key, _ in pairs(path_cache) do
        if string.find(key, "^" .. navmesh_id .. "_") then
            table.insert(keys_to_remove, key)
        end
    end
    
    for _, key in ipairs(keys_to_remove) do
        path_cache[key] = nil
    end
end

return RecastAPI 