-- script/task/task_mgr.lua
local skynet = require "skynet"
local task_def = require "task.task_def"
local task_event = require "task.task_event"
local task_condition = require "task.task_condition"
local task_reward = require "task.task_reward"

local TaskMgr = {}
local mt = { __index = TaskMgr }

function TaskMgr.new(player)
    local obj = {
        player = player,
        tasks = {},           -- 当前任务列表
        completed_tasks = {}, -- 已完成任务列表
        event_handlers = {},  -- 事件处理器
    }
    setmetatable(obj, mt)
    return obj
end

-- 初始化任务管理器
function TaskMgr:init()
    -- 注册事件监听
    self:register_event_handlers()
    -- 加载玩家任务数据
    self:load_player_tasks()
end

-- 注册事件处理器
function TaskMgr:register_event_handlers()
    local eventS = skynet.uniqueservice("eventS")
    
    -- 注册所有任务相关事件
    for _, event_type in pairs(task_def.EVENT_TYPE) do
        skynet.call(eventS, "lua", "subscribe", event_type, skynet.self())
    end
    
    -- 设置事件处理函数
    self.event_handlers = {
        [task_def.EVENT_TYPE.LEVEL_UP] = function(...)
            self:on_level_up(...)
        end,
        [task_def.EVENT_TYPE.ITEM_CHANGE] = function(...)
            self:on_item_change(...)
        end,
        -- 其他事件处理函数...
    }
end

-- 加载玩家任务数据
function TaskMgr:load_player_tasks()
    -- 从数据库加载玩家任务数据
    local db_tasks = skynet.call("dbS", "lua", "load_player_tasks", self.player.id)
    
    for _, task_data in ipairs(db_tasks) do
        self.tasks[task_data.task_id] = task_data
    end
end

-- 接受任务
function TaskMgr:accept_task(task_id)
    local task_config = task_loader.get_task_config(task_id)
    if not task_config then
        return false, "任务不存在"
    end
    
    -- 检查前置任务
    if not self:check_pre_tasks(task_config.pre_tasks) then
        return false, "前置任务未完成"
    end
    
    -- 检查任务条件
    if not task_condition.check_accept_conditions(self.player, task_config) then
        return false, "不满足接取条件"
    end
    
    -- 创建任务数据
    local task_data = {
        task_id = task_id,
        state = task_def.TASK_STATE.ACCEPTED,
        progress = {},
        accept_time = os.time()
    }
    
    -- 初始化任务进度
    for _, condition in ipairs(task_config.conditions) do
        task_data.progress[condition.id] = 0
    end
    
    -- 保存任务数据
    self.tasks[task_id] = task_data
    skynet.call("dbS", "lua", "save_player_task", self.player.id, task_data)
    
    -- 触发任务接受事件
    task_event.on_task_accepted(self.player, task_id)
    
    return true
end

-- 更新任务进度
function TaskMgr:update_task_progress(task_id, condition_id, progress)
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
function TaskMgr:complete_task(task_id)
    local task_data = self.tasks[task_id]
    if not task_data or task_data.state ~= task_def.TASK_STATE.ACCEPTED then
        return false
    end
    
    task_data.state = task_def.TASK_STATE.COMPLETED
    task_data.complete_time = os.time()
    
    -- 保存任务状态
    skynet.call("dbS", "lua", "update_task_state", self.player.id, task_id, task_data.state)
    
    -- 触发任务完成事件
    task_event.on_task_completed(self.player, task_id)
    
    return true
end

-- 领取任务奖励
function TaskMgr:get_task_reward(task_id)
    local task_data = self.tasks[task_id]
    if not task_data or task_data.state ~= task_def.TASK_STATE.COMPLETED then
        return false, "任务未完成"
    end
    
    -- 发放奖励
    local success, msg = task_reward.give_rewards(self.player, task_id)
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
    task_event.on_task_rewarded(self.player, task_id)
    
    return true
end

-- 事件处理函数
function TaskMgr:on_level_up(player_id, data)
    if player_id ~= self.player.id then return end
    
    -- 检查所有任务中的等级条件
    for task_id, task_data in pairs(self.tasks) do
        if task_data.state == task_def.TASK_STATE.ACCEPTED then
            local task_config = task_loader.get_task_config(task_id)
            for _, condition in ipairs(task_config.conditions) do
                if condition.type == task_def.CONDITION_TYPE.LEVEL then
                    self:update_task_progress(task_id, condition.id, data.new_level)
                end
            end
        end
    end
end

function TaskMgr:on_item_change(player_id, data)
    if player_id ~= self.player.id then return end
    
    -- 检查所有任务中的物品条件
    for task_id, task_data in pairs(self.tasks) do
        if task_data.state == task_def.TASK_STATE.ACCEPTED then
            local task_config = task_loader.get_task_config(task_id)
            for _, condition in ipairs(task_config.conditions) do
                if condition.type == task_def.CONDITION_TYPE.ITEM then
                    local item_count = self.player:get_item_count(condition.item_id)
                    self:update_task_progress(task_id, condition.id, item_count)
                end
            end
        end
    end
end

return TaskMgr