local skynet = require "skynet"
local class = require "utils.class"
local ctn_kv = require "container.ctn_kv"
local event_def = require "define.event_def"
local condition_def = require "define.condition_def"

-- 使用class模块实现继承
local ctn_task = class("ctn_task", ctn_kv)

-- 构造函数
function ctn_task:ctor(player)
    -- 调用父类构造函数
    ctn_task.super.ctor(self, player)
    
    -- 任务相关属性
    self.tasks = {}           -- 当前任务列表 {task_id = task_data}
    self.completed_tasks = {} -- 已完成任务列表
    self.condition_subscriptions = {} -- 条件订阅列表 {condition_id = {task_id = true}}
    
    -- 初始化任务数据
    self:init_tasks()
end

-- 初始化任务数据
function ctn_task:init_tasks()
    -- 从数据库加载玩家任务数据
    local db_tasks = skynet.call("dbS", "lua", "load_player_tasks", self.player.id)
    for _, task_data in ipairs(db_tasks) do
        self.tasks[task_data.task_id] = task_data
    end
end

-- 接受任务
function ctn_task:accept_task(task_id)
    local task_config = require("config.task_config")[task_id]
    if not task_config then
        return false, "任务不存在"
    end
    
    -- 检查前置任务
    if not self:check_pre_tasks(task_config.pre_tasks) then
        return false, "前置任务未完成"
    end
    
    -- 检查接取条件
    if not self:check_accept_conditions(task_config) then
        return false, "不满足接取条件"
    end
    
    -- 创建任务数据
    local task_data = {
        task_id = task_id,
        state = task_def.TASK_STATE.ACCEPTED,
        progress = {},
        accept_time = os.time()
    }
    
    -- 初始化任务进度并订阅条件
    for _, condition in ipairs(task_config.conditions) do
        task_data.progress[condition.id] = 0
        self:subscribe_condition(condition.id, condition.params, task_id)
    end
    
    -- 保存任务数据
    self.tasks[task_id] = task_data
    skynet.call("dbS", "lua", "save_player_task", self.player.id, task_data)
    
    -- 触发任务接受事件
    self:trigger_event(event_def.PLAYER_TASK_ACCEPT, task_id)
    
    return true
end

-- 订阅条件
function ctn_task:subscribe_condition(condition_id, condition_params, task_id)
    if not self.condition_subscriptions[condition_id] then
        self.condition_subscriptions[condition_id] = {}
    end
    
    -- 记录任务订阅
    self.condition_subscriptions[condition_id][task_id] = true
    
    -- 订阅条件变化,设置always_notify为true以接收所有变化
    self.player.condition:subscribe(condition_id, condition_params, function(value)
        self:on_condition_changed(condition_id, task_id, value)
    end, true)
end

-- 取消订阅条件
function ctn_task:unsubscribe_condition(condition_id, task_id)
    if self.condition_subscriptions[condition_id] then
        self.condition_subscriptions[condition_id][task_id] = nil
        
        -- 如果没有其他任务订阅这个条件,则取消订阅
        if not next(self.condition_subscriptions[condition_id]) then
            self.condition_subscriptions[condition_id] = nil
            self.player.condition:unsubscribe(condition_id)
        end
    end
end

-- 条件变化回调
function ctn_task:on_condition_changed(condition_id, task_id, value)
    local task_data = self.tasks[task_id]
    if not task_data or task_data.state ~= task_def.TASK_STATE.ACCEPTED then
        return
    end
    
    -- 更新任务进度
    self:update_task_progress(task_id, condition_id, value)
end

-- 更新任务进度
function ctn_task:update_task_progress(task_id, condition_id, progress)
    local task_data = self.tasks[task_id]
    if not task_data or task_data.state ~= task_def.TASK_STATE.ACCEPTED then
        return false
    end
    
    -- 更新进度
    task_data.progress[condition_id] = progress
    
    -- 检查任务是否完成
    if self:check_task_completed(task_id) then
        self:complete_task(task_id)
    else
        -- 保存进度
        skynet.call("dbS", "lua", "update_task_progress", self.player.id, task_id, condition_id, progress)
    end
    
    return true
end

-- 完成任务
function ctn_task:complete_task(task_id)
    local task_data = self.tasks[task_id]
    if not task_data or task_data.state ~= task_def.TASK_STATE.ACCEPTED then
        return false
    end
    
    -- 取消所有条件订阅
    local task_config = require("config.task_config")[task_id]
    for _, condition in ipairs(task_config.conditions) do
        self:unsubscribe_condition(condition.id, task_id)
    end
    
    task_data.state = task_def.TASK_STATE.COMPLETED
    task_data.complete_time = os.time()
    
    -- 保存任务状态
    skynet.call("dbS", "lua", "update_task_state", self.player.id, task_id, task_data.state)
    
    -- 触发任务完成事件
    self:trigger_event(event_def.PLAYER_TASK_COMPLETE, task_id)
    
    return true
end

-- 领取任务奖励
function ctn_task:get_task_reward(task_id)
    local task_data = self.tasks[task_id]
    if not task_data or task_data.state ~= task_def.TASK_STATE.COMPLETED then
        return false, "任务未完成"
    end
    
    -- 发放奖励
    local success, msg = self:give_task_rewards(task_id)
    if not success then
        return false, msg
    end
    
    -- 更新任务状态
    task_data.state = task_def.TASK_STATE.REWARDED
    skynet.call("dbS", "lua", "update_task_state", self.player.id, task_id, task_data.state)
    
    -- 从当前任务列表中移除
    self.tasks[task_id] = nil
    self.completed_tasks[task_id] = task_data
    
    -- 触发任务领奖事件
    self:trigger_event(event_def.PLAYER_TASK_REWARD, task_id)
    
    return true
end

-- 检查前置任务
function ctn_task:check_pre_tasks(pre_tasks)
    if not pre_tasks then return true end
    
    for _, task_id in ipairs(pre_tasks) do
        if not self.completed_tasks[task_id] then
            return false
        end
    end
    return true
end

-- 检查接取条件
function ctn_task:check_accept_conditions(task_config)
    -- 检查等级要求
    if task_config.require_level and self.player.level < task_config.require_level then
        return false
    end
    
    -- 检查职业要求
    if task_config.require_class and self.player.class ~= task_config.require_class then
        return false
    end
    
    return true
end

-- 检查任务完成
function ctn_task:check_task_completed(task_id)
    local task_data = self.tasks[task_id]
    if not task_data then return false end
    
    local task_config = require("config.task_config")[task_id]
    for _, condition in ipairs(task_config.conditions) do
        local current = task_data.progress[condition.id] or 0
        if current < condition.target then
            return false
        end
    end
    
    return true
end

-- 发放任务奖励
function ctn_task:give_task_rewards(task_id)
    local task_config = require("config.task_config")[task_id]
    if not task_config then
        return false, "任务不存在"
    end
    
    -- 检查背包空间
    if not self.player.bag:check_space(task_config.rewards) then
        return false, "背包空间不足"
    end
    
    -- 发放奖励
    for _, reward in ipairs(task_config.rewards) do
        if reward.type == "item" then
            self.player.bag:add_item(reward.id, reward.count)
        elseif reward.type == "exp" then
            self.player:add_exp(reward.value)
        elseif reward.type == "money" then
            self.player:add_money(reward.value)
        end
    end
    
    return true
end

-- 触发事件
function ctn_task:trigger_event(event_name, ...)
    local eventS = skynet.uniqueservice("event")
    skynet.call(eventS, "lua", "trigger", event_name, self.player.id, ...)
end

return ctn_task
