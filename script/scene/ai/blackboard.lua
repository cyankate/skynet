local class = require "utils.class"
local log = require "log"

-- 黑板系统（简化版）
local Blackboard = class("Blackboard")

function Blackboard:ctor(entity)
    self.entity = entity
    
    -- 统一数据存储
    self.data = {}
    
    -- 监听器
    self.listeners = {}
    
    -- 数据变化标记
    self.dirty_flags = {}
    
    -- 历史记录
    self.history = {}
    self.max_history = 100
end

-- 统一的数据操作方法
function Blackboard:get(key, default_value)
    return self.data[key] or default_value
end

function Blackboard:set(key, value)
    local old_value = self.data[key]
    if old_value ~= value then
        -- 记录历史
        self:add_history(key, old_value, value)
        
        self.data[key] = value
        self:mark_dirty(key)
        self:notify_listeners(key, old_value, value)
        log.debug("Blackboard: 设置数据 %s = %s", key, tostring(value))
    end
end

function Blackboard:clear(key)
    local old_value = self.data[key]
    if old_value ~= nil then
        -- 记录历史
        self:add_history(key, old_value, nil)
        
        self.data[key] = nil
        self:mark_dirty(key)
        self:notify_listeners(key, old_value, nil)
        log.debug("Blackboard: 清除数据 %s", key)
    end
end

-- 检查数据是否存在
function Blackboard:has(key)
    return self.data[key] ~= nil
end

-- 获取所有数据
function Blackboard:get_all()
    return self.data
end

-- 清除所有数据
function Blackboard:clear_all()
    for key, _ in pairs(self.data) do
        self:clear(key)
    end
end

-- 标记数据为脏
function Blackboard:mark_dirty(key)
    self.dirty_flags[key] = true
end

-- 检查数据是否脏
function Blackboard:is_dirty(key)
    return self.dirty_flags[key] == true
end

-- 清除脏标记
function Blackboard:clear_dirty(key)
    self.dirty_flags[key] = nil
end

-- 清除所有脏标记
function Blackboard:clear_all_dirty()
    self.dirty_flags = {}
end

-- 添加监听器
function Blackboard:add_listener(key, callback, context)
    if not self.listeners[key] then
        self.listeners[key] = {}
    end
    
    table.insert(self.listeners[key], {
        callback = callback,
        context = context
    })
end

-- 移除监听器
function Blackboard:remove_listener(key, callback)
    if self.listeners[key] then
        for i, listener in ipairs(self.listeners[key]) do
            if listener.callback == callback then
                table.remove(self.listeners[key], i)
                break
            end
        end
    end
end

-- 通知监听器
function Blackboard:notify_listeners(key, old_value, new_value)
    if self.listeners[key] then
        for _, listener in ipairs(self.listeners[key]) do
            if listener.callback then
                listener.callback(key, old_value, new_value, listener.context)
            end
        end
    end
end

-- 添加历史记录
function Blackboard:add_history(key, old_value, new_value)
    if #self.history >= self.max_history then
        table.remove(self.history, 1)
    end
    
    table.insert(self.history, {
        key = key,
        old_value = old_value,
        new_value = new_value,
        timestamp = os.time()
    })
end

-- 获取历史记录
function Blackboard:get_history(key, limit)
    local result = {}
    local count = 0
    limit = limit or 10
    
    for i = #self.history, 1, -1 do
        local record = self.history[i]
        if record.key == key then
            table.insert(result, record)
            count = count + 1
            if count >= limit then
                break
            end
        end
    end
    
    return result
end

-- 清除历史记录
function Blackboard:clear_history()
    self.history = {}
end

-- 调试方法
function Blackboard:dump()
    log.debug("Blackboard: 当前数据:")
    for key, value in pairs(self.data) do
        log.debug("  %s = %s", key, tostring(value))
    end
end

return Blackboard 