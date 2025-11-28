local skynet = require "skynet"
local CtnKv = require "ctn.ctn_kv"
local log = require "log" 
local condition_def = require "define.condition_def"

local CtnCondition = class("CtnCondition", CtnKv)

function CtnCondition:ctor(player)
    CtnCondition.super.ctor(self, player)
    
    -- 条件数据
    self.conditions = {
        level = 1,              -- 当前等级
        chapters = {},          -- 已通关章节 {chapter_id = true}
        stages = {},            -- 已通关关卡 {stage_id = true}
        equip_quality = {},     -- 装备品质统计 {quality = count}
        equip_level = {},       -- 装备等级统计 {level = count}
    }
    
    -- 订阅者表
    self.subscribers = {}
    
    -- 初始化条件数据
    self:init_conditions()
end

-- 初始化条件数据
function CtnCondition:init_conditions()
    -- 从数据库加载玩家条件数据
    local ok, db_conditions = pcall(function()
        return skynet.call("dbS", "lua", "load_player_conditions", self.player.id)
    end)
    
    if ok and db_conditions then
        for k, v in pairs(db_conditions) do
            self.conditions[k] = v
        end
    else
        log.error("Failed to load player conditions:", db_conditions)
    end
end

-- 订阅单个条件
function CtnCondition:subscribe(condition_type, condition_data, callback, always_notify)
    if not condition_type or not condition_data or not callback then
        log.error("Invalid parameters for subscribe")
        return
    end
    
    if not self.subscribers[condition_type] then
        self.subscribers[condition_type] = {}
    end
    
    -- 生成条件唯一标识
    local condition_id = self:generate_condition_id(condition_type, condition_data)
    
    -- 保存订阅信息
    self.subscribers[condition_type][condition_id] = {
        data = condition_data,
        callback = callback,
        always_notify = always_notify or false
    }
    
    -- 立即检查条件是否满足
    self:check_condition(condition_type, condition_id)
    
    return condition_id
end

-- 订阅多个条件
function CtnCondition:subscribe_multiple(conditions, callback)
    if not conditions or not callback then
        log.error("Invalid parameters for subscribe_multiple")
        return
    end
    
    local results = {}
    local condition_ids = {}
    
    -- 为每个条件创建订阅
    for _, condition in ipairs(conditions) do
        if condition.type and condition.data then
            local condition_id = self:generate_condition_id(condition.type, condition.data)
            table.insert(condition_ids, condition_id)
            
            self:subscribe(condition.type, condition.data, function(value)
                results[condition.type] = value
                -- 检查所有条件是否都满足
                if self:check_multiple_conditions(conditions, results) then
                    callback(results)
                end
            end)
        end
    end
    
    return condition_ids
end

-- 检查多个条件是否都满足
function CtnCondition:check_multiple_conditions(conditions, results)
    for _, condition in ipairs(conditions) do
        local current_value = results[condition.type]
        if not current_value or not self:is_condition_met(condition.type, current_value, condition.data) then
            return false
        end
    end
    return true
end

-- 取消订阅单个条件
function CtnCondition:unsubscribe(condition_type, condition_data)
    if not condition_type or not condition_data then
        log.error("Invalid parameters for unsubscribe")
        return
    end
    
    if self.subscribers[condition_type] then
        local condition_id = self:generate_condition_id(condition_type, condition_data)
        self.subscribers[condition_type][condition_id] = nil
    end
end

-- 取消订阅多个条件
function CtnCondition:unsubscribe_multiple(condition_ids)
    if not condition_ids then
        log.error("Invalid parameters for unsubscribe_multiple")
        return
    end
    
    for _, condition_id in ipairs(condition_ids) do
        local condition_type, condition_data = self:parse_condition_id(condition_id)
        if condition_type and condition_data then
            self:unsubscribe(condition_type, condition_data)
        end
    end
end

-- 生成条件ID
function CtnCondition:generate_condition_id(condition_type, condition_data)
    local data_str = ""
    if type(condition_data) == "table" then
        local values = {}
        for k, v in pairs(condition_data) do
            table.insert(values, tostring(v))
        end
        data_str = table.concat(values, "_")
    else
        data_str = tostring(condition_data)
    end
    return string.format("%s_%s", condition_type, data_str)
end

-- 解析条件ID
function CtnCondition:parse_condition_id(condition_id)
    if not condition_id then return nil, nil end
    
    local parts = string.split(condition_id, "_")
    if #parts < 2 then return nil, nil end
    
    local condition_type = parts[1]
    local condition_data = {}
    
    -- 解析条件数据
    for i = 2, #parts do
        table.insert(condition_data, parts[i])
    end
    
    return condition_type, condition_data
end

-- 获取条件值
function CtnCondition:get_condition_value(condition_type, data)
    if not condition_type or not data then
        log.error("Invalid parameters for get_condition_value")
        return nil
    end
    
    local handler = condition_def.handlers.get_value[condition_type]
    if handler then
        return handler(self, data)
    end
    return nil
end

-- 判断条件是否满足
function CtnCondition:is_condition_met(condition_type, current_value, data)
    if not condition_type or not data then
        log.error("Invalid parameters for is_condition_met")
        return false
    end
    
    local handler = condition_def.handlers.is_met[condition_type]
    if handler then
        return handler(current_value, data)
    end
    return false
end

-- 更新条件值
function CtnCondition:update_condition(condition_type, value)
    if not condition_type then
        log.error("Invalid parameters for update_condition")
        return
    end
    
    local handler = condition_def.handlers.update[condition_type]
    if handler then
        local check_type = handler(self, value)
        self:check_all_conditions(check_type)
        
        -- 保存到数据库
        pcall(function()
            skynet.call("dbS", "lua", "update_player_condition", self.player.id, condition_type, value)
        end)
    end
end

-- 更新装备条件
function CtnCondition:update_equip_condition(quality, level)
    if not quality or not level then
        log.error("Invalid parameters for update_equip_condition")
        return
    end
    
    self.conditions.equip_quality[quality] = (self.conditions.equip_quality[quality] or 0) + 1
    self.conditions.equip_level[level] = (self.conditions.equip_level[level] or 0) + 1
    
    -- 检查所有装备相关条件
    self:check_all_conditions(condition_def.EQUIP.QUALITY_COUNT)
    self:check_all_conditions(condition_def.EQUIP.LEVEL_SUM)
    
    -- 保存到数据库
    pcall(function()
        skynet.call("dbS", "lua", "update_player_equip_condition", self.player.id, {
            quality = self.conditions.equip_quality,
            level = self.conditions.equip_level
        })
    end)
end

-- 检查条件
function CtnCondition:check_condition(condition_type, condition_id)
    local subscriber = self.subscribers[condition_type][condition_id]
    if not subscriber then return end
    
    local data = subscriber.data
    local current_value = self:get_condition_value(condition_type, data)
    
    -- 如果设置了always_notify,则无论条件是否满足都触发回调
    if subscriber.always_notify then
        subscriber.callback(current_value)
    else
        -- 否则只在条件满足时触发回调
        local is_met = self:is_condition_met(condition_type, current_value, data)
        if is_met then
            subscriber.callback(current_value)
        end
    end
end

-- 检查所有相关条件
function CtnCondition:check_all_conditions(condition_type)
    if self.subscribers[condition_type] then
        for condition_id, _ in pairs(self.subscribers[condition_type]) do
            self:check_condition(condition_type, condition_id)
        end
    end
end

-- 清理所有订阅
function CtnCondition:clear_subscribers()
    self.subscribers = {}
end

return CtnCondition
