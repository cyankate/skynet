-- script/system/task/task_def.lua

local task_def = {
    TASK_TYPE = {
        MAIN = 1,
        SIDE = 2,
        DAILY = 3,
        ACHIEVE = 4,
        GUILD = 5,
    },

    TASK_STATE = {
        NONE = 0,
        ACCEPTED = 1,
        COMPLETED = 2,
        REWARDED = 3,
    },

    -- 进度计数方式
    COUNT_MODE = {
        LIFETIME = "lifetime",         -- 历史累计（默认）
        SINCE_ACCEPT = "since_accept", -- 接取后的增量
    },
}

return task_def
