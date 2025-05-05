-- script/task/task_loader.lua
local task_loader = {}

local task_configs = {}

-- 加载任务配置
function task_loader.load()
    -- 从配置文件加载任务数据
    local configs = require "config.task_config"
    
    for _, config in ipairs(configs) do
        task_configs[config.id] = config
    end
end

-- 获取任务配置
function task_loader.get_task_config(task_id)
    return task_configs[task_id]
end

return task_loader