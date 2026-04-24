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

local PlayType = {
    NORMAL = 1,
    DAILY_MATCH = 2,
}

local PlayIndexInstanceType = {
    [PlayType.NORMAL] = InstanceType.SINGLE,
    [PlayType.DAILY_MATCH] = InstanceType.MULTI,
}

local InstanceEndType = {
    NORMAL = 1,       -- 正常结束（胜负/通关等）
    ACTIVE_QUIT = 2,  -- 主动离开导致结束
    TIMEOUT = 3,      -- 超时结束
    SYSTEM_KICK = 4,  -- 系统踢出
    DISCONNECT = 5,   -- 断线结束
    ERROR = 6,        -- 异常结束
}

local InstanceEndReason = {
    NORMAL_WIN = 101,
    NORMAL_LOSE = 102,
    NORMAL_DRAW = 103,
    QUIT_ALL = 201,
    QUIT_OWNER = 202,
    TIMEOUT_CLIENT = 301,
    TIMEOUT_SERVER = 302,
    KICK_SYSTEM = 401,
    DISCONNECT_ALL = 501,
    DISCONNECT_OWNER = 502,
    ERROR_EXCEPTION = 601,
}

return {
    InstanceStatus = InstanceStatus,
    InstanceType = InstanceType,
    PlayType = PlayType,
    PlayIndexInstanceType = PlayIndexInstanceType,
    InstanceEndType = InstanceEndType,
    InstanceEndReason = InstanceEndReason,
}