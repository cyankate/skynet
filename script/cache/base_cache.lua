local skynet = require "skynet"
local log = require "log"
local class = require "utils.class"
local common = require "utils.common"

-- 基础缓存管理类
local base_cache = class("base_cache")

-- 构造函数
function base_cache:ctor(name, config)
    self.name = name
    self.config = config or {
        max_size = 3000,           -- 最大缓存条目数
        ttl = 3600,               -- 默认过期时间（秒）
        cleanup_interval = 300,   -- 清理间隔（秒）
        load_timeout = 5,         -- 加载超时时间（秒）
    }
    self.cache = {}              -- 缓存数据
    self.access_time = {}        -- 最后访问时间
    self.size = 0                -- 当前缓存大小
    self.cleanup_running = false -- 清理是否正在运行
    self.loading = {}            -- 正在加载的数据 {key = {waiting = {}, loading = true, timeout = timeout}}
    self.dirty_keys = {}         -- 需要保存的key
    self.news = {}               -- 需要插入的key
    -- 统计信息
    self.hit_count = 0           -- 缓存命中次数
    self.miss_count = 0          -- 缓存未命中次数
    self.load_timeout_count = 0  -- 加载超时次数
end

-- 移除最旧的缓存项
function base_cache:remove_oldest()
    local oldest_key = nil
    local oldest_time = os.time()
    
    for key, time in pairs(self.access_time) do
        if time < oldest_time then
            oldest_time = time
            oldest_key = key
        end
    end
    
    if oldest_key then
        self:remove(oldest_key)
    end
end

-- 获取加载锁
function base_cache:acquire_load(key)
    if not self.loading[key] then
        self.loading[key] = {
            waiting = {},
            loading = true,
            timeout = common.set_timeout(self.config.load_timeout * 100, function()
                self:handle_load_timeout(key)
            end),
        }
        return true
    end
    -- 如果已经在加载中，等待加载完成
    local co = coroutine.running()
    table.insert(self.loading[key].waiting, co)
    skynet.wait(co)
    return false
end

-- 处理加载超时
function base_cache:handle_load_timeout(key)
    local loading_info = self.loading[key]
    if loading_info then
        -- 唤醒所有等待的协程，并传递超时错误
        for _, co in ipairs(loading_info.waiting) do
            skynet.wakeup(co, "timeout")
        end
        -- 清理加载信息
        self.loading[key] = nil
        self.load_timeout_count = self.load_timeout_count + 1
        log.error(string.format("Cache load timeout for key: %s", key))
    end
end

-- 释放加载锁
function base_cache:release_load(key, data)
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

-- 获取缓存项
function base_cache:get(key)
    local item = self.cache[key]
    local result = nil
    
    if item then
        -- 更新访问时间，即使数据已过期
        self.access_time[key] = os.time()
        result = item.data
        self.hit_count = self.hit_count + 1
    else
        self.miss_count = self.miss_count + 1
    end
    
    -- 如果缓存未命中且提供了加载器，则尝试加载
    if not result then
        -- 尝试获取加载锁
        local is_first_loader = self:acquire_load(key)
        if is_first_loader then
            -- 第一个加载者
            result = self:load_item(key)
            if result then
                self:set(key, result)
            else 
                log.error("load_item failed for key: " .. key)  
            end
            self:release_load(key, result)
        else
            item = self.cache[key]
            if item then
                result = item.data
            end
        end
    end
    
    return result
end

function base_cache:load_item(key)
    return nil
end

-- 设置缓存项
function base_cache:set(key, value, ttl)
    -- 如果缓存已满，移除最旧的项
    if self.size >= self.config.max_size then
        self:remove_oldest()
    end
    
    ttl = ttl or self.config.ttl
    self.cache[key] = {
        data = value,
        expire_time = os.time() + ttl
    }
    self.access_time[key] = os.time()
    self.size = self.size + 1
end

-- 批量获取缓存项
function base_cache:batch_get(keys, loader)
    if not keys or type(keys) ~= "table" then
        return {}
    end
    
    local results = {}
    local miss_keys = {}
    
    -- 先尝试从缓存获取
    for _, key in ipairs(keys) do
        local item = self.cache[key]
        if item then
            -- 更新访问时间，即使数据已过期
            self.access_time[key] = os.time()
            results[key] = item.data
            self.hit_count = self.hit_count + 1
        else
            table.insert(miss_keys, key)
            self.miss_count = self.miss_count + 1
        end
    end
    
    -- 如果提供了加载器，尝试加载未命中的数据
    if #miss_keys == 0 or not loader then
        return results
    end
    
    -- 对每个未命中的key获取加载锁
    local loading_keys = {}
    local waiting_keys = {}
    
    for _, key in ipairs(miss_keys) do
        -- 先检查是否已经在加载中
        if self.loading[key] then
            table.insert(waiting_keys, key)
        else
            -- 尝试获取加载锁
            if self:acquire_load(key) then
                table.insert(loading_keys, key)
            else 
                log.error("acquire_load failed for key: " .. key)
            end
        end
    end
    
    -- 加载需要加载的数据
    if #loading_keys > 0 then
        local loaded_data = loader(loading_keys)
        if loaded_data then
            -- 更新缓存
            self:batch_set(loaded_data)
            -- 更新结果
            for key, value in pairs(loaded_data) do
                results[key] = value
            end
        end
        
        -- 释放加载锁
        for _, key in ipairs(loading_keys) do
            self:release_load(key)
        end
    end
    
    -- 如果没有需要等待的key，直接返回结果
    if #waiting_keys == 0 then
        return results
    end
    
    -- 先检查缓存，过滤掉已经加载好的数据
    local still_waiting = {}
    for _, key in ipairs(waiting_keys) do
        local item = self.cache[key]
        if item then
            results[key] = item.data
        else
            table.insert(still_waiting, key)
        end
    end
    
    -- 只等待还没加载好的数据
    if #still_waiting == 0 then
        return results
    end
    
    for _, key in ipairs(still_waiting) do
        local co = coroutine.running()
        local timeout = skynet.wait(co)
        if timeout == "timeout" then
            log.error(string.format("Cache load timeout for key: %s", key))
        end
        local item = self.cache[key]
        if item then
            results[key] = item.data
        end
    end
    
    return results
end

-- 批量设置缓存项
function base_cache:batch_set(items, ttl)
    if not items or type(items) ~= "table" then
        return false
    end
    
    ttl = ttl or self.config.ttl
    local now = os.time()
    local expire_time = now + ttl
    
    -- 检查是否需要清理空间
    local need_cleanup = self.size + #items > self.config.max_size
    if need_cleanup then
        local to_remove = self.size + #items - self.config.max_size
        for i = 1, to_remove do
            self:remove_oldest()
        end
    end
    
    -- 批量设置
    for key, value in pairs(items) do
        self.cache[key] = {
            data = value,
            expire_time = expire_time
        }
        self.access_time[key] = now
        self.size = self.size + 1
    end
    
    return true
end

function base_cache:mark_dirty(key)
    self.dirty_keys[key] = true
end

function base_cache:is_dirty(key)
    return self.dirty_keys[key] or self.news[key]
end

function base_cache:save_all()
    for key, item in pairs(self.cache) do
        if type(key) ~= "number" and type(key) ~= "string" then
           log.error("save_all key is not a number or string: " .. key)
        end
        if self:is_dirty(key) then
            self:save_item(key, item)
        end
    end
end

function base_cache:save_item(key, item)
    local data = item.data
    local ret = self:save(key, data)
    if ret then
        self.dirty_keys[key] = nil
    end
end

function base_cache:save(key, data)
    return true
end

function base_cache:tick()
    self:save_all()
    self:cleanup()
end

-- 清理过期数据
function base_cache:cleanup()
    if self.cleanup_running then
        return
    end
    self.cleanup_running = true
    
    local now = os.time()
    for key, item in pairs(self.cache) do
        if now > item.expire_time then
            if self:is_dirty(key) then
                self:save_item(key, item)
            end
            self.cache[key] = nil
            self.access_time[key] = nil
            self.size = self.size - 1
        end
    end
    
    self.cleanup_running = false
end

-- 删除缓存项
function base_cache:remove(key)
    self.cache[key] = nil
    self.access_time[key] = nil
    self.size = self.size - 1
end

-- 清空缓存
function base_cache:clear()
    self.cache = {}
    self.access_time = {}
    self.size = 0
    self.hit_count = 0
    self.miss_count = 0
    self.load_timeout_count = 0
end

-- 获取缓存统计信息
function base_cache:get_stats()
    return {
        size = self.size,
        max_size = self.config.max_size,
        ttl = self.config.ttl,
        cleanup_interval = self.config.cleanup_interval,
        hit_count = self.hit_count,
        miss_count = self.miss_count,
        load_timeout_count = self.load_timeout_count,
        hit_rate = self.hit_count / (self.hit_count + self.miss_count)
    }
end

return base_cache 