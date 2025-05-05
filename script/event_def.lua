-- event_def.lua
local event_def = {
    -- 玩家生命周期事件 (由agent服务触发)
    PLAYER = {
        LOGIN = "player.login",           -- 玩家登录
        LOGOUT = "player.logout",         -- 玩家登出
        LEVEL_UP = "player.level_up",     -- 玩家升级
        VIP_LEVEL_UP = "player.vip_level_up", -- VIP等级提升
    },
    
    -- 战斗相关事件 (由battle服务触发)
    BATTLE = {
        START = "battle.start",           -- 战斗开始
        END = "battle.end",               -- 战斗结束
        WIN = "battle.win",               -- 战斗胜利
        LOSE = "battle.lose",             -- 战斗失败
    },
    
    -- 赛季相关事件 (由season服务触发)
    SEASON = {
        START = "season.start",           -- 赛季开始
        END = "season.end",               -- 赛季结束
        REWARD = "season.reward",         -- 赛季奖励发放
    },
    
}