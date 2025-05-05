-- script/task/task_condition.lua
local task_def = require "task.task_def"
local task_condition = {}

-- 检查接取任务条件
function task_condition.check_accept_conditions(player, task_config)
    -- 检查等级要求
    if task_config.require_level and player.level < task_config.require_level then
        return false
    end
    
    -- 检查职业要求
    if task_config.require_class and player.class ~= task_config.require_class then
        return false
    end
    
    -- 检查前置任务
    if task_config.pre_tasks then
        for _, pre_task_id in ipairs(task_config.pre_tasks) do
            if not player.task_mgr:is_task_completed(pre_task_id) then
                return false
            end
        end
    end
    
    return true
end

-- 检查任务完成条件
function task_condition.check_complete_conditions(player, task_id)
    local task_data = player.task_mgr.tasks[task_id]
    if not task_data then return false end
    
    local task_config = task_loader.get_task_config(task_id)
    for _, condition in ipairs(task_config.conditions) do
        local current = task_data.progress[condition.id] or 0
        if current < condition.target then
            return false
        end
    end
    
    return true
end

return task_condition