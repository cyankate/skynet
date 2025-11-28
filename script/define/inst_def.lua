-- 副本状态枚举
local InstanceStatus = {
    CREATING = 1,    -- 创建中
    WAITING = 2,     -- 等待玩家进入
    RUNNING = 3,     -- 运行中
    PAUSED = 4,      -- 暂停
    COMPLETED = 5,   -- 已完成
    FAILED = 6,      -- 失败
    DESTROYING = 7   -- 销毁中
}

local InstanceType = {
    SINGLE = 1,
    MULTI = 2,
}

return {
    InstanceStatus = InstanceStatus,
    InstanceType = InstanceType
}