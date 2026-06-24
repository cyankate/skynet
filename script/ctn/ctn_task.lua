local skynet = require "skynet"
local CtnKv = require "ctn.ctn_kv"
local class = require "utils.class"
local user_mgr = require "user_mgr"
local event_def = require "define.event_def"
local task_def = require "system.task.task_def"
local task_mgr = require "system.task.task_mgr"
local head_mgr = require "system.head_mgr"
local item_mgr = require "system.item_mgr"
local log = require "log"

local TASKS_KEY = "tasks"
local COMPLETED_KEY = "completed_tasks"

local CtnTask = class("CtnTask", CtnKv)

function CtnTask:ctor(_player_id, _tbl, _name)
    CtnKv.ctor(self, _player_id, _tbl, _name)
    self.condition_subscriptions_ = {}
end

function CtnTask:onload(data)
    CtnKv.onload(self, data)
    if type(self:get(TASKS_KEY)) ~= "table" then
        self:set(TASKS_KEY, {})
    end
    if type(self:get(COMPLETED_KEY)) ~= "table" then
        self:set(COMPLETED_KEY, {})
    end
end

function CtnTask:init_player()
    self:set(TASKS_KEY, {})
    self:set(COMPLETED_KEY, {})
    self.condition_subscriptions_ = {}
end

function CtnTask:get_tasks()
    return self:get(TASKS_KEY) or {}
end

function CtnTask:get_completed_tasks()
    return self:get(COMPLETED_KEY) or {}
end

function CtnTask:on_player_loaded(player)
    self.condition_subscriptions_ = {}
    for task_id, task_data in pairs(self:get_tasks()) do
        if task_data.state == task_def.TASK_STATE.ACCEPTED then
            task_data.baseline = task_data.baseline or {}
            local task_config = task_mgr.get_task_config(task_id)
            if task_config then
                for _, condition in ipairs(task_config.conditions or {}) do
                    self:subscribe_condition(player, condition, task_id, task_data)
                end
            end
        end
    end
end

function CtnTask:accept_task(player, task_id)
    task_id = tonumber(task_id)
    local task_config = task_mgr.get_task_config(task_id)
    if not task_config then
        return false, "任务不存在"
    end
    if self:get_tasks()[task_id] then
        return false, "任务已接取"
    end

    if not self:check_pre_tasks(task_config.pre_tasks) then
        return false, "前置任务未完成"
    end
    if not self:check_accept_conditions(player, task_config) then
        return false, "不满足接取条件"
    end

    local task_data = {
        task_id = task_id,
        state = task_def.TASK_STATE.ACCEPTED,
        progress = {},
        baseline = {},
        accept_time = os.time(),
    }

    for _, condition in ipairs(task_config.conditions or {}) do
        local progress_key = self:get_progress_key(condition)
        self:init_condition_baseline(player, condition, task_data, progress_key)
        task_data.progress[progress_key] = 0
        self:subscribe_condition(player, condition, task_id, task_data)
    end

    local tasks = self:get_tasks()
    tasks[task_id] = task_data
    self:set(TASKS_KEY, tasks)
    self:trigger_event(event_def.PLAYER.TASK_ACCEPT, task_id)
    task_mgr.notify_task_update(player, task_id)
    return true
end

function CtnTask:get_progress_key(condition)
    return condition.id or condition.key or condition.type
end

function CtnTask:get_count_mode(condition)
    return condition.count_mode or task_def.COUNT_MODE.LIFETIME
end

function CtnTask:get_condition_ctn(player)
    return player and player:get_ctn("condition")
end

function CtnTask:normalize_baseline(raw_value)
    if type(raw_value) == "boolean" then
        return raw_value and 1 or 0
    end
    return tonumber(raw_value) or 0
end

function CtnTask:init_condition_baseline(player, condition, task_data, progress_key)
    if self:get_count_mode(condition) ~= task_def.COUNT_MODE.SINCE_ACCEPT then
        return
    end
    local condition_ctn = self:get_condition_ctn(player)
    if not condition_ctn then
        return
    end
    local raw_value = condition_ctn:get_condition_value(condition.type, condition.params or {})
    task_data.baseline[progress_key] = self:normalize_baseline(raw_value)
end

function CtnTask:calc_progress(condition, task_data, raw_value)
    local count_mode = self:get_count_mode(condition)
    local progress_key = self:get_progress_key(condition)

    if type(raw_value) == "boolean" then
        local current = raw_value and 1 or 0
        if count_mode == task_def.COUNT_MODE.SINCE_ACCEPT then
            local baseline = tonumber(task_data.baseline and task_data.baseline[progress_key]) or 0
            return math.max(0, current - baseline)
        end
        return current
    end

    local current = tonumber(raw_value) or 0
    if count_mode == task_def.COUNT_MODE.SINCE_ACCEPT then
        local baseline = tonumber(task_data.baseline and task_data.baseline[progress_key]) or 0
        return math.max(0, current - baseline)
    end
    return current
end

function CtnTask:subscribe_condition(player, condition, task_id, task_data)
    local condition_ctn = self:get_condition_ctn(player)
    if not condition_ctn then
        log.error("condition container not found for player %s", tostring(self.prikey_))
        return
    end

    local condition_type = condition.type
    local condition_params = condition.params or {}
    local progress_key = self:get_progress_key(condition)
    if not condition_type then
        return
    end

    local listener_id = condition_ctn:subscribe(condition_type, condition_params, function(value)
        self:on_condition_changed(player, condition, task_id, value)
    end, true)

    if not listener_id then
        return
    end

    self.condition_subscriptions_[task_id] = self.condition_subscriptions_[task_id] or {}
    self.condition_subscriptions_[task_id][#self.condition_subscriptions_[task_id] + 1] = listener_id

    local progress = self:calc_progress(condition, task_data, condition_ctn:get_condition_value(condition_type, condition_params))
    self:update_task_progress(task_id, progress_key, progress)
end

function CtnTask:unsubscribe_task_conditions(player, task_id)
    local condition_ctn = self:get_condition_ctn(player)
    local subscriptions = self.condition_subscriptions_[task_id]
    if condition_ctn and subscriptions then
        for _, listener_id in ipairs(subscriptions) do
            condition_ctn:unsubscribe_listener(listener_id)
        end
    end
    self.condition_subscriptions_[task_id] = nil
end

function CtnTask:on_condition_changed(player, condition, task_id, value)
    local task_data = self:get_tasks()[task_id]
    if not task_data or task_data.state ~= task_def.TASK_STATE.ACCEPTED then
        return
    end

    local progress_key = self:get_progress_key(condition)
    local progress = self:calc_progress(condition, task_data, value)
    self:update_task_progress(task_id, progress_key, progress)
end

function CtnTask:update_task_progress(task_id, progress_key, progress)
    local tasks = self:get_tasks()
    local task_data = tasks[task_id]
    if not task_data or task_data.state ~= task_def.TASK_STATE.ACCEPTED then
        return false
    end

    task_data.progress[progress_key] = progress
    self:set(TASKS_KEY, tasks)

    local player = user_mgr.get_player_obj(self.prikey_)
    if player then
        task_mgr.notify_task_update(player, task_id)
    end

    if self:check_task_completed(task_id) then
        return self:complete_task(task_id)
    end
    return true
end

function CtnTask:complete_task(task_id)
    local tasks = self:get_tasks()
    local task_data = tasks[task_id]
    if not task_data or task_data.state ~= task_def.TASK_STATE.ACCEPTED then
        return false
    end

    local player = user_mgr.get_player_obj(self.prikey_)
    if player then
        self:unsubscribe_task_conditions(player, task_id)
    end

    task_data.state = task_def.TASK_STATE.COMPLETED
    task_data.complete_time = os.time()
    self:set(TASKS_KEY, tasks)
    self:trigger_event(event_def.PLAYER.TASK_COMPLETE, task_id)
    if player then
        task_mgr.notify_task_update(player, task_id)
    end
    return true
end

function CtnTask:get_task_reward(player, task_id)
    task_id = tonumber(task_id)
    local tasks = self:get_tasks()
    local task_data = tasks[task_id]
    if not task_data or task_data.state ~= task_def.TASK_STATE.COMPLETED then
        return false, "任务未完成"
    end

    local ok, msg = self:give_task_rewards(player, task_id)
    if not ok then
        return false, msg
    end

    tasks[task_id] = nil
    self:set(TASKS_KEY, tasks)

    local completed = self:get_completed_tasks()
    task_data.state = task_def.TASK_STATE.REWARDED
    completed[task_id] = task_data
    self:set(COMPLETED_KEY, completed)
    self:trigger_event(event_def.PLAYER.TASK_REWARD, task_id)
    return true
end

function CtnTask:is_task_completed(task_id)
    local completed = self:get_completed_tasks()
    if completed[task_id] then
        return true
    end
    local task_data = self:get_tasks()[task_id]
    return task_data and task_data.state >= task_def.TASK_STATE.COMPLETED
end

function CtnTask:check_pre_tasks(pre_tasks)
    if not pre_tasks then
        return true
    end
    for _, pre_task_id in ipairs(pre_tasks) do
        if not self:is_task_completed(pre_task_id) then
            return false
        end
    end
    return true
end

function CtnTask:check_accept_conditions(player, task_config)
    if task_config.require_level then
        if head_mgr.get_head_level(player) < task_config.require_level then
            return false
        end
    end
    if task_config.require_class and player.class_ and player.class_ ~= task_config.require_class then
        return false
    end
    return true
end

function CtnTask:check_task_completed(task_id)
    local task_data = self:get_tasks()[task_id]
    if not task_data then
        return false
    end
    local task_config = task_mgr.get_task_config(task_id)
    if not task_config then
        return false
    end
    for _, condition in ipairs(task_config.conditions or {}) do
        local progress_key = self:get_progress_key(condition)
        local current = tonumber(task_data.progress[progress_key]) or 0
        if current < (tonumber(condition.target) or 0) then
            return false
        end
    end
    return true
end

function CtnTask:give_task_rewards(player, task_id)
    local task_config = task_mgr.get_task_config(task_id)
    if not task_config then
        return false, "任务不存在"
    end

    local reward_items = {}
    for _, reward in ipairs(task_config.rewards or {}) do
        if reward.type == "item" then
            reward_items[reward.id] = (reward_items[reward.id] or 0) + (reward.count or 0)
        end
    end

    if next(reward_items) then
        local ok, err = item_mgr.can_add_items(player, reward_items)
        if not ok then
            return false, err or "背包空间不足"
        end
        local add_ok, add_err = item_mgr.add_items(player, reward_items, "task_reward")
        if not add_ok then
            return false, add_err or "发放奖励失败"
        end
    end

    for _, reward in ipairs(task_config.rewards or {}) do
        if reward.type == "exp" then
            head_mgr.add_head_exp(player, reward.value or 0)
        end
    end

    return true
end

function CtnTask:trigger_event(event_name, ...)
    local eventS = skynet.localname(".event")
    if not eventS then
        return
    end
    skynet.send(eventS, "lua", "trigger", event_name, self.prikey_, ...)
end

return CtnTask
