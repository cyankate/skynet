local skynet = require "skynet"
local log = require "log"
local class = require "utils.class"
local common = require "utils.common"
local table_schema = require "sql.table_schema"

-- 基础缓存管理类
local BaseCache = class("BaseCache")

local DB_OPTS = {
    INSERT = 1,
    UPDATE = 2,
    DELETE = 3,
}

-- 构造函数
function BaseCache:ctor(name, tbl_name, config)
    self.name = name
    self.tbl_name = tbl_name
    self.config = {
        max_size = 1000,           -- 最大缓存条目数
        load_timeout = 10,         -- 加载超时时间（秒）
        stats_window = 60,       -- 访问统计窗口（秒）
        min_decay_rate = 0.01,    -- 最小衰减速率
        max_decay_rate = 2,      -- 最大衰减速率
        base_decay_rate = 0.1,   -- 基础衰减速率
        protection_window = 60,  -- 新数据保护期（秒）
        base_score = 100,        -- 基础分数
        -- 压力等级配置
        pressure_levels = {
            {
                threshold = 1.0,   -- 100%容量
                multiplier = 1.2   -- 衰减速率1.2倍
            },
            {
                threshold = 1.5,   -- 150%容量
                multiplier = 2.0   -- 衰减速率2倍
            },
            {
                threshold = 2.0,   -- 200%容量
                multiplier = 3.0   -- 衰减速率3倍
            },
            {
                threshold = 3.0,   -- 300%容量
                multiplier = 5.0   -- 衰减速率5倍
            },
        }
    }
    for k, v in pairs(config or {}) do
        self.config[k] = v
    end
    self.cache = {}              -- 缓存数据 {key = {obj = xxx, score = xxx, create_time = xxx}}
    self.size = 0                -- 当前缓存大小
    self.cleanup_running = false -- 清理是否正在运行
    self.loading = {}            -- 正在加载的数据
    self.dirty_keys = {}         -- 脏标记
    self.insert_keys = {}        -- 插入标记
    self.db_inserting = {}       -- 数据库插入标记
    self.last_decay_time = os.time() -- 上次衰减时间
    -- 访问统计
    self.access_stats = {
        window_start_time = os.time(),
        window_access_count = 0,
        last_window_rate = 0,
    }
    -- 压力统计
    self.pressure_stats = {
        current_level = 0,
        level_duration = {},
        level_change_time = os.time()
    }
    -- 统计信息
    self.hit_count = 0
    self.miss_count = 0
end

-- 获取加载锁
function BaseCache:acquire_load(key, no_wait)
    if not self.loading[key] then
        self.loading[key] = {
            waiting = {},
            timeout = common.set_timeout(self.config.load_timeout * 100, function()
                self:handle_load_timeout(key)
            end),
        }
        return true
    end
    -- 如果已经在加载中，等待加载完成
    local co = coroutine.running()
    table.insert(self.loading[key].waiting, co)
    if not no_wait then
        local timeout = skynet.wait(co)
    end
    return false
end

-- 处理加载超时
function BaseCache:handle_load_timeout(key)
    log.error("[%s] load_timeout for key: %s", self.name, key)
    local loading_info = self.loading[key]
    if loading_info then
        -- 清理加载信息
        self.loading[key] = nil
        -- 唤醒所有等待的协程，并传递超时错误
        for _, co in ipairs(loading_info.waiting) do
            skynet.wakeup(co, "timeout")
        end
    end
end

-- 释放加载锁
function BaseCache:release_load(key)
    local loading_info = self.loading[key]
    if loading_info then
        -- 取消超时定时器
        if loading_info.timeout then
            loading_info.timeout()
        end
        -- 唤醒所有等待的协程
        for _, co in ipairs(loading_info.waiting) do
            skynet.wakeup(co)
        end
        -- 清理加载信息
        self.loading[key] = nil
    end
end

-- 获取当前压力等级和衰减倍数
function BaseCache:get_pressure_level(memory_pressure)
    local current_level = 0
    local multiplier = 1
    
    -- 遍历压力等级配置
    for i, level in ipairs(self.config.pressure_levels) do
        if memory_pressure >= level.threshold then
            current_level = i
            multiplier = level.multiplier
        else
            break
        end
    end
    
    -- 更新压力统计
    if current_level ~= self.pressure_stats.current_level then
        local now = os.time()
        local duration = now - self.pressure_stats.level_change_time
        
        -- 记录上一个等级的持续时间
        self.pressure_stats.level_duration[self.pressure_stats.current_level] = 
            (self.pressure_stats.level_duration[self.pressure_stats.current_level] or 0) + duration
        
        -- 更新当前等级
        self.pressure_stats.current_level = current_level
        self.pressure_stats.level_change_time = now
        
        -- 记录压力等级变化日志
        if current_level > 0 then
            log.warning(string.format("Cache pressure level changed to %d (%.1f%% of max_size)", 
                current_level, memory_pressure * 100))
        end
    end
    
    return multiplier
end

-- 更新访问统计
function BaseCache:update_access_stats(count)
    local now = os.time()
    local window_size = self.config.stats_window
    self.access_stats.window_access_count = self.access_stats.window_access_count + count

    -- 检查是否需要切换统计窗口
    if now - self.access_stats.window_start_time >= window_size then
        -- 计算上一个窗口的访问率（每秒访问次数）
        local window_duration = now - self.access_stats.window_start_time
        local current_rate = self.access_stats.window_access_count / window_duration
        if self.access_stats.last_window_rate == 0 then
            self.access_stats.last_window_rate = current_rate
        else 
            self.access_stats.last_window_rate = 
                current_rate * 0.3 + self.access_stats.last_window_rate * 0.7
        end

        -- 重置统计窗口
        self.access_stats.window_start_time = now
        self.access_stats.window_access_count = 0
        
        log.info(string.format("Cache access rate updated: %.2f requests/sec, access_count: %s, window_size: %s", 
            self.access_stats.last_window_rate, self.access_stats.window_access_count, window_size))
    end
end

-- 计算基础衰减速率
function BaseCache:calculate_base_decay_rate()
    -- 根据当前访问率动态调整衰减速率
    local rate = self.access_stats.last_window_rate
    if rate <= 0 then
        return self.config.max_decay_rate  -- 无访问时使用最大衰减速率
    end

    -- 计算每个缓存项的平均访问率
    local avg_rate_per_item = self.size > 0 and (rate / self.size) or 0
    
    -- 使用指数函数计算衰减率：访问率越高，衰减率越低
    local decay_rate = self.config.base_decay_rate * math.exp(-avg_rate_per_item)
    
    -- 限制在配置的范围内
    decay_rate = math.max(self.config.min_decay_rate, 
                         math.min(decay_rate, self.config.max_decay_rate))
    
    return decay_rate
end

-- 更新全局衰减
function BaseCache:update_decay()
    local now = os.time()
    local elapsed = now - self.last_decay_time
    if elapsed <= 0 then
        return
    end

    -- 计算当前内存压力
    local memory_pressure = self.size / self.config.max_size
    
    -- 获取当前压力等级的衰减倍数
    local pressure_multiplier = self:get_pressure_level(memory_pressure)
    
    -- 获取基础衰减速率
    local base_rate = self:calculate_base_decay_rate()
    -- 计算本次需要衰减的分数
    local decay_score = math.floor(elapsed * base_rate * pressure_multiplier * 100) / 100
    if decay_score > 0 then
        -- 对每个缓存项进行衰减
        for key, item in pairs(self.cache) do
            item.score = math.max(0, item.score - decay_score)
        end
        
        self.last_decay_time = now
    end 
end

-- 获取缓存项
function BaseCache:get(key)
    -- 更新访问统计
    self:update_access_stats(1)
    
    local item = self.cache[key]
    local result = nil
    
    if item then
        -- 增加访问得分
        item.score = item.score + 1
        result = item.obj
        self.hit_count = self.hit_count + 1
    else
        self.miss_count = self.miss_count + 1
    end
    
    -- 如果缓存未命中且提供了加载器，则尝试加载
    if not result then
        local is_first_loader = self:acquire_load(key)
        if is_first_loader then
            result = self:get_from_redis(key)
            if result then
                self:set(key, result)
            else 
                log.error("[%s] get_from_redis failed for key: %s", self.name, key)  
            end
            self:release_load(key)
        else
            item = self.cache[key]
            if item then
                result = item.obj
            else
                log.error("[%s] item not found for key: %s", self.name, key)
            end
        end
    end
    
    return result
end

function BaseCache:get_from_redis(key)
    local redis = skynet.localname(".redis")
    if redis then
        local redis_key = self.name .. ":" .. key
        local data = skynet.call(redis, "lua", "get", redis_key)
        if data then
            local obj = self:new_item(key)
            obj:onload(tableUtils.deserialize_table(data))
            return obj
        end
    else 
        log.error("[%s] redis is not running", self.name)
    end 
    return self:load_item({key})[key]
end

function BaseCache:set_to_redis(key, obj)
    local redis = skynet.localname(".redis")
    if not redis then
        log.error("[%s] redis is not running", self.name)
        return 
    end 
    local redis_key = self.name .. ":" .. key
    skynet.call(redis, "lua", "set", redis_key, tableUtils.serialize_table(obj:onsave()))
end 

--override
function BaseCache:new_item(key)
    return nil
end

function BaseCache:load_item(keys)
    local datas = self:batch_load(keys)
    local results = {}
    for _, key in pairs(keys) do
        local data = datas[key]
        local obj = self:new_item(key)
        if not obj then 
            log.error("[%s] new_item failed for key: %s", self.name, key)
            return 
        end 
        if data then
            obj:onload(data)
        else
            self.insert_keys[key] = true
        end
        results[key] = obj
    end 
    return results
end

-- 设置缓存项
function BaseCache:set(key, value)
    self.cache[key] = {
        obj = value,
        score = self.config.base_score,  -- 初始分数
        create_time = os.time()          -- 创建时间
    }
    self.size = self.size + 1
end

-- 从缓存中批量获取数据
function BaseCache:get_from_cache(keys)
    local results = {}
    local miss_keys = {}
    
    for _, key in ipairs(keys) do
        if type(key) ~= "string" and type(key) ~= "number" then
            log.error(string.format("[%s] invalid key type in get_from_cache: %s", self.name, type(key)))
            goto continue
        end
        
        local item = self.cache[key]
        if item then
            -- 增加访问得分
            item.score = item.score + 1
            results[key] = item.obj
            self.hit_count = self.hit_count + 1
        else
            table.insert(miss_keys, key)
            self.miss_count = self.miss_count + 1
        end
        ::continue::
    end
    
    return results, miss_keys
end

-- 获取加载锁并分类keys
function BaseCache:classify_keys(keys)
    local loading_keys = {}     -- 记录获取到加载锁的key
    local waiting_keys = {}     -- 记录需要等待的key
    
    for _, key in ipairs(keys) do
        if self.loading[key] then
            -- 已经在加载中，加入等待列表
            table.insert(waiting_keys, key)
        else
            -- 尝试获取加载锁
            if self:acquire_load(key) then
                table.insert(loading_keys, key)
            else
                -- 获取锁失败，加入等待列表
                table.insert(waiting_keys, key)
            end
        end
    end
    
    return loading_keys, waiting_keys
end

-- 从Redis批量加载数据
function BaseCache:batch_load_from_redis(loading_keys)
    local results = {}
    local unloaded_keys = {}  -- 记录Redis未命中需要从DB加载的key
    
    local redis = skynet.localname(".redis")
    if not redis then
        -- Redis不可用，所有key都需要从DB加载
        return results, loading_keys
    end
    local redis_keys = {}
    for _, key in ipairs(loading_keys) do
        table.insert(redis_keys, self.name .. ":" .. key)
    end
    
    local redis_results = skynet.call(redis, "lua", "mget", table.unpack(redis_keys))
    if redis_results then
        for i, key in ipairs(loading_keys) do
            -- 重新检查内存中是否已有数据
            local item = self.cache[key]
            if item then
                results[key] = item.obj
                goto continue
            end
            
            -- 处理Redis中的数据
            local data = redis_results[i]
            if data then
                local obj = self:new_item(key)
                if obj then
                    obj:onload(tableUtils.deserialize_table(data))
                    -- 设置到缓存
                    self:set(key, obj)
                    results[key] = obj
                end
            else
                -- Redis未命中或数据为nil，加入待DB加载列表
                table.insert(unloaded_keys, key)
            end
            ::continue::
        end
    else
        -- Redis查询失败，所有key都需要从DB加载
        for _, key in ipairs(loading_keys) do
            -- 重新检查内存中是否已有数据
            local item = self.cache[key]
            if item then
                results[key] = item.obj
            else
                table.insert(unloaded_keys, key)
            end
        end
    end
    
    return results, unloaded_keys
end

-- 从DB批量加载数据
function BaseCache:batch_load_from_db(keys)
    local results = {}
    local loaded = {}
    
    local objs = self:load_item(keys)
    for _, key in ipairs(keys) do
        loaded[key] = objs[key]
    end
    
    -- 批量设置到缓存
    if next(loaded) then
        self:batch_set(loaded)
        -- 更新结果
        for key, obj in pairs(loaded) do
            results[key] = obj
        end
    end
    
    return results
end

-- 等待其他协程加载完成
function BaseCache:wait_for_loading(waiting_keys, results)
    for _, key in ipairs(waiting_keys) do
        local co = coroutine.running()
        if self.loading[key] then
            table.insert(self.loading[key].waiting, co)
            local timeout = skynet.wait(co)
            if timeout == "timeout" then
                goto continue
            end
        end
        
        -- 等待完成后检查缓存
        local item = self.cache[key]
        if item then
            results[key] = item.obj
        end
        ::continue::
    end
    return results
end

-- 批量获取缓存项
function BaseCache:batch_get(keys)
    if not keys or type(keys) ~= "table" or #keys == 0 then
        return {}
    end
    
    -- 1. 先从缓存中获取
    local results, miss_keys = self:get_from_cache(keys)
    if #miss_keys == 0 then
        return results
    end
    
    -- 2. 对未命中的key进行分类
    local loading_keys, waiting_keys = self:classify_keys(miss_keys)
    
    -- 3. 处理可以主动加载的keys
    if #loading_keys > 0 then
        -- 3.1 先从Redis加载
        local redis_results, unloaded_keys = self:batch_load_from_redis(loading_keys)
        -- 合并Redis的结果
        for k, v in pairs(redis_results) do
            results[k] = v
        end
        
        -- 3.2 对Redis未命中的key从DB加载
        if #unloaded_keys > 0 then
            local db_results = self:batch_load_from_db(unloaded_keys)
            -- 合并DB的结果
            for k, v in pairs(db_results) do
                results[k] = v
            end 
            if tableUtils.table_size(db_results) ~= #unloaded_keys then
                log.error("batch_get, load db fail")
            end
        end
        
        -- 3.3 释放所有加载锁
        for _, key in ipairs(loading_keys) do
            self:release_load(key)
        end
    end
    
    -- 4. 最后等待其他正在加载的key
    if #waiting_keys > 0 then
        results = self:wait_for_loading(waiting_keys, results)
    end
    if tableUtils.table_size(results) ~= #keys then
        log.error("batch_get, load fail")
    end
    return results
end

-- 批量设置缓存项
function BaseCache:batch_set(items)
    if not items or type(items) ~= "table" then
        return false
    end
    
    local now = os.time()
    local count = 0
    
    -- 预先检查空间
    for _ in pairs(items) do
        count = count + 1
    end
    
    -- 批量设置到缓存
    for key, value in pairs(items) do
        if type(key) ~= "string" and type(key) ~= "number" then
            log.error(string.format("[%s] invalid key type in batch_set: %s", self.name, type(key)))
            goto continue
        end
        
        -- 设置缓存项
        self.cache[key] = {
            obj = value,
            score = self.config.base_score,  -- 初始分数
            create_time = now               -- 创建时间
        }
        self.size = self.size + 1
        
        ::continue::
    end
    
    return true
end

function BaseCache:mark_dirty(key)
    local num = self.dirty_keys[key] or 0
    self.dirty_keys[key] = num + 1
end

function BaseCache:is_dirty(key)
    return self.dirty_keys[key] or not self.insert_keys[key]
end

function BaseCache:save_all()
    local objs = {}
    for key, item in pairs(self.cache) do
        if self:is_dirty(key) then
            objs[key] = item.obj
        end
    end
    local batch_size = 20
    local total_count = tableUtils.table_size(objs)
    local count = 0
    for _, obj in pairs(objs) do
        count = count + 1
        if count % batch_size == 0 or count == total_count then
            self:batch_save(objs)
            objs = {}
        end
    end
end

function BaseCache:batch_save(objs)
    local insert_objs = {}
    local update_objs = {}
    for key, obj in pairs(objs) do
        if self.insert_keys[key] then
            if not self.db_inserting[key] then
                table.insert(insert_objs, obj)
            end 
        elseif self.dirty_keys[key] then
            table.insert(update_objs, obj)
        end
    end
    if #insert_objs > 0 then
        local ret = self:batch_insert(insert_objs)
        if not ret then
            log.error(string.format("[%s] batch_save insert failed", self.name))
            return false
        end
        for _, obj in ipairs(insert_objs) do
            self.insert_keys[obj:get_key()] = nil
            self.db_inserting[obj:get_key()] = nil
        end
    end
    if #update_objs > 0 then
        local ret = self:batch_update(update_objs)
        if not ret then
            log.error(string.format("[%s] batch_save update failed", self.name))
            return false
        end
        for _, obj in ipairs(update_objs) do
            self.dirty_keys[obj:get_key()] = nil
        end
    end
    return true
end

--override
function BaseCache:batch_load(keys)
    local dbS = skynet.localname(".db")
    local struct = table_schema[self.tbl_name]
    local primary_key = struct.primary_keys[1]
    local ret = skynet.call(dbS, "lua", "select", self.tbl_name, {
        [primary_key] = keys,
    })
    local rows = {}
    for _, v in pairs(ret) do 
        rows[v[primary_key]] = v
    end 
    local datas = {}
    for _, key in ipairs(keys) do
        if rows[key] then
            datas[key] = rows[key]
        end
    end
    return datas
end

--override
function BaseCache:batch_update(objs)
    local dbS = skynet.localname(".db")
    local data_list = {}
    for _, obj in pairs(objs) do
        local data = obj:onsave()
        table.insert(data_list, data)
    end
    local ret = skynet.call(dbS, "lua", "batch_update", self.tbl_name, data_list)
    return ret
end

--override
function BaseCache:batch_insert(objs)
    local dbS = skynet.localname(".db")
    local data_list = {}
    for _, obj in pairs(objs) do
        local data = obj:onsave()
        table.insert(data_list, data)
    end
    local ret = skynet.call(dbS, "lua", "batch_insert", self.tbl_name, data_list)
    return ret
end

function BaseCache:tick()
    self:save_all()
    self:cleanup()
end

-- 清理过期数据
function BaseCache:cleanup()
    if self.cleanup_running then
        return
    end
    if self.cleanup_time and os.time() - self.cleanup_time < 5 then
        return
    end
    self.cleanup_time = os.time()
    self.cleanup_running = true
    
    -- 更新衰减
    self:update_decay()
    
    local to_delete = {}
    local now = os.time()
    
    -- 收集需要删除的键
    for key, item in pairs(self.cache) do
        -- 只清理保护期之外的数据
        if now - item.create_time > self.config.protection_window and item.score <= 0 then
            table.insert(to_delete, key)
        end
    end
    
    -- 执行删除
    local batch_size = 20
    local count = 0
    local save_objs = {}
    for _, key in ipairs(to_delete) do
        local item = self.cache[key]
        self.cache[key] = nil
        self.size = self.size - 1
        count = count + 1
        save_objs[key] = item.obj
        if count % batch_size == 0 or count == #to_delete then
            self:batch_save(save_objs)
            save_objs = {}
        end
    end
    
    self.cleanup_running = false
end

-- 删除缓存项
function BaseCache:remove(key)
    local item = self.cache[key]
    if item then
        self:set_to_redis(key, item.obj)
    end
    self.cache[key] = nil
    self.size = self.size - 1
end

-- 清空缓存
function BaseCache:clear()
    self.cache = {}
    self.size = 0
    self.hit_count = 0
    self.miss_count = 0
end

-- 获取缓存统计信息
function BaseCache:get_stats()
    local stats = {
        size = self.size,
        max_size = self.config.max_size,
        memory_pressure = self.size / self.config.max_size,
        hit_count = self.hit_count,
        miss_count = self.miss_count,
        hit_rate = self.hit_count / (self.hit_count + self.miss_count),
        current_pressure_level = self.pressure_stats.current_level,
        pressure_level_duration = {}
    }
    
    -- 添加各压力等级的持续时间统计
    for level, duration in pairs(self.pressure_stats.level_duration) do
        stats.pressure_level_duration[level] = duration
    end
    
    -- 更新当前等级的持续时间
    if self.pressure_stats.current_level > 0 then
        local current_duration = os.time() - self.pressure_stats.level_change_time
        stats.pressure_level_duration[self.pressure_stats.current_level] = 
            (stats.pressure_level_duration[self.pressure_stats.current_level] or 0) + current_duration
    end
    
    return stats
end

return BaseCache 