local class = require "utils.class"
local log = require "log"

-- 黑板系统
local Blackboard = class("Blackboard")

function Blackboard:ctor()
    self.data = {}                    -- 数据存储
    self.entity = nil                 -- 关联实体
    self.sync_config = {}             -- 同步配置
    self.listeners = {}               -- 数据变化监听器
    self.history = {}                 -- 数据历史记录
    self.max_history = 100            -- 最大历史记录数
end

-- 设置关联实体
function Blackboard:set_entity(entity)
    self.entity = entity
    return self
end

-- 添加同步配置
function Blackboard:add_sync_config(key, config)
    self.sync_config[key] = config
    return self
end

-- 设置数据（核心方法）
function Blackboard:set(key, value, source)
    local old_value = self.data[key]
    
    -- 如果值没有变化，不处理
    if old_value == value then
        return true
    end
    
    -- 记录历史
    self:add_history(key, old_value, value, source)
    
    -- 更新数据
    self.data[key] = value
    
    -- 自动同步到实体
    self:sync_to_entity(key)
    
    -- 触发监听器
    self:notify_listeners(key, old_value, value, source)
    
    log.debug("Blackboard: 设置数据 %s = %s (来源: %s)", key, tostring(value), source or "unknown")
    
    return true
end

-- 获取数据
function Blackboard:get(key, default_value)
    return self.data[key] or default_value
end

-- 检查数据是否存在
function Blackboard:has(key)
    return self.data[key] ~= nil
end

-- 移除数据
function Blackboard:remove(key, source)
    if not self:has(key) then
        return false
    end
    
    local old_value = self.data[key]
    
    -- 记录历史
    self:add_history(key, old_value, nil, source)
    
    -- 删除数据
    self.data[key] = nil
    
    -- 自动同步到实体
    self:sync_to_entity(key)
    
    -- 触发监听器
    self:notify_listeners(key, old_value, nil, source)
    
    log.debug("Blackboard: 移除数据 %s (来源: %s)", key, source or "unknown")
    
    return true
end

-- 自动同步到实体
function Blackboard:sync_to_entity(key)
    if not self.entity then
        return false
    end
    
    local config = self.sync_config[key]
    if not config then
        return false
    end
    
    local value = self.data[key]
    local entity_value = value
    
    -- 应用转换函数
    if config.transform and value ~= nil then
        entity_value = config.transform(value, self.entity)
    end
    
    -- 设置到实体属性
    self.entity[config.entity_attr] = entity_value
    
    log.debug("Blackboard: 同步到实体 %s.%s = %s", 
              self.entity.id, config.entity_attr, tostring(entity_value))
    
    return true
end

-- 获取实体的属性值（优先从黑板获取）
function Blackboard:get_entity_attr(attr_name)
    if not self.entity then
        return nil
    end
    
    -- 查找对应的黑板key
    for key, config in pairs(self.sync_config) do
        if config.entity_attr == attr_name then
            local value = self.data[key]
            if config.transform and value ~= nil then
                return config.transform(value, self.entity)
            end
            return value
        end
    end
    
    -- 如果没找到配置，直接从实体获取
    return self.entity[attr_name]
end

-- 添加数据变化监听器
function Blackboard:add_listener(key, callback, context)
    if not self.listeners[key] then
        self.listeners[key] = {}
    end
    
    table.insert(self.listeners[key], {
        callback = callback,
        context = context
    })
    
    log.debug("Blackboard: 添加监听器 %s", key)
end

-- 移除数据变化监听器
function Blackboard:remove_listener(key, callback)
    if not self.listeners[key] then
        return false
    end
    
    for i, listener in ipairs(self.listeners[key]) do
        if listener.callback == callback then
            table.remove(self.listeners[key], i)
            log.debug("Blackboard: 移除监听器 %s", key)
            return true
        end
    end
    
    return false
end

-- 通知监听器
function Blackboard:notify_listeners(key, old_value, new_value, source)
    if not self.listeners[key] then
        return
    end
    
    for _, listener in ipairs(self.listeners[key]) do
        local success, err = pcall(listener.callback, key, old_value, new_value, source, listener.context)
        if not success then
            log.error("Blackboard: 监听器执行失败 %s: %s", key, err)
        end
    end
end

-- 添加历史记录
function Blackboard:add_history(key, old_value, new_value, source)
    if #self.history >= self.max_history then
        table.remove(self.history, 1)
    end
    
    table.insert(self.history, {
        key = key,
        old_value = old_value,
        new_value = new_value,
        source = source,
        timestamp = os.time()
    })
end

-- 获取历史记录
function Blackboard:get_history(key, limit)
    local result = {}
    limit = limit or 10
    
    for i = #self.history, 1, -1 do
        if #result >= limit then
            break
        end
        
        local record = self.history[i]
        if not key or record.key == key then
            table.insert(result, 1, record)
        end
    end
    
    return result
end

-- 清空历史记录
function Blackboard:clear_history()
    self.history = {}
end

-- 获取所有数据
function Blackboard:get_all_data()
    local result = {}
    for key, value in pairs(self.data) do
        result[key] = value
    end
    return result
end

-- 批量设置数据
function Blackboard:set_multiple(data_table, source)
    local results = {}
    for key, value in pairs(data_table) do
        results[key] = self:set(key, value, source)
    end
    return results
end

-- 批量获取数据
function Blackboard:get_multiple(keys)
    local result = {}
    for _, key in ipairs(keys) do
        result[key] = self:get(key)
    end
    return result
end

-- 获取同步状态（用于调试）
function Blackboard:get_sync_status()
    local status = {
        sync_config = {},
        entity_values = {},
        blackboard_values = {}
    }
    
    if self.entity then
        for key, config in pairs(self.sync_config) do
            status.sync_config[key] = config
            status.entity_values[key] = self.entity[config.entity_attr]
            status.blackboard_values[key] = self.data[key]
        end
    end
    
    return status
end

-- 清空黑板
function Blackboard:clear()
    self.data = {}
    self.listeners = {}
    self.history = {}
    log.info("Blackboard: 黑板已清空")
end

-- 调试信息
function Blackboard:debug_info()
    local stats = {
        total_keys = 0,
        listeners_count = 0,
        history_count = #self.history,
        sync_config_count = 0
    }
    
    for _ in pairs(self.data) do
        stats.total_keys = stats.total_keys + 1
    end
    
    for _, listeners in pairs(self.listeners) do
        stats.listeners_count = stats.listeners_count + #listeners
    end
    
    for _ in pairs(self.sync_config) do
        stats.sync_config_count = stats.sync_config_count + 1
    end
    
    log.info("Blackboard 调试信息:")
    log.info("  总数据项: %d", stats.total_keys)
    log.info("  监听器: %d", stats.listeners_count)
    log.info("  历史记录: %d", stats.history_count)
    log.info("  同步配置: %d", stats.sync_config_count)
    
    if stats.total_keys > 0 then
        log.info("  数据项:")
        for key, value in pairs(self.data) do
            log.info("    %s = %s", key, tostring(value))
        end
    end
end

return Blackboard 