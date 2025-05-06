-- 匹配状态定义
local match_def = {
    STATE = {
        WAITING = 0,    -- 等待匹配
        MATCHED = 1,    -- 已匹配
        READY = 2,      -- 准备就绪
        CANCELED = 3,   -- 已取消
    },
    
    -- 匹配事件
    EVENT = {
        MATCH_START = "match.start",           -- 开始匹配
        MATCH_SUCCESS = "match.success",       -- 匹配成功
        MATCH_CANCEL = "match.cancel",         -- 取消匹配
        MATCH_TIMEOUT = "match.timeout",       -- 匹配超时
    },
    
    -- 匹配类型
    TYPE = {
        RANK = "rank",          -- 排位赛
        CASUAL = "casual",      -- 休闲赛
        CUSTOM = "custom",      -- 自定义
    },
}

return match_def 