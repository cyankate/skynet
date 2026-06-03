-- script/system/task/task_def.lua
local event_def = require "define.event_def"

local task_def = {
    -- 任务类型
    TASK_TYPE = {
        MAIN = 1,       -- 主线任务
        SIDE = 2,       -- 支线任务
        DAILY = 3,      -- 日常任务
        ACHIEVE = 4,    -- 成就任务
        GUILD = 5,      -- 公会任务
    },
    
    -- 任务状态
    TASK_STATE = {
        NONE = 0,       -- 未接取
        ACCEPTED = 1,   -- 已接取
        COMPLETED = 2,  -- 已完成
        REWARDED = 3,   -- 已领奖
    },
    
}

return task_def