-- event_def.lua：事件名常量
-- AGENT.*  → runtime.agent_event（agent 进程内同步 dispatch）
-- 其余     → .event 服务 subscribe / trigger（跨服务）
local event_def = {
    -- agent 进程内（agent_event.register / trigger，不经 skynet）
    AGENT = {
        --- 养成效果重建完成（head/talent 等变更后 collect_player_effects）
        EFFECTS_CHANGED = "agent.effects_changed",
    },

    -- 玩家生命周期（多由 agent 触发，经 .event 广播到其他服务）
    PLAYER = {
        LOGIN = "player.login",
        --- 连接断开（含闪断宽限期内暂离，玩家对象仍在 agent 内存）
        LOGOUT = "player.logout",
        --- 玩家从 agent 内存卸载（宽限期结束、关服等），用于「真正离线」业务
        OFFLINE = "player.offline",
        LEVEL_UP = "player.level_up",
        ITEM_CHANGE = "player.item_change",
        TASK_ACCEPT = "player.task_accept",
        TASK_COMPLETE = "player.task_complete",
        TASK_REWARD = "player.task_reward",
        COLLECT_ITEM = "player.collect_item",
        TALK_NPC = "player.talk_npc",
        USE_ITEM = "player.use_item",
        REACH_PLACE = "player.reach_place",
    },

    -- 公会（多由 guild 服务触发）
    GUILD = {
        CREATE = "guild.create",
        DISMISS = "guild.dismiss",
    },

    -- 战斗（由 battle / 副本等触发）
    BATTLE = {
        START = "battle.start",
        END = "battle.end",
        WIN = "battle.win",
        LOSE = "battle.lose",
        KILL_MONSTER = "battle.kill_monster",
    },

    -- 赛季（由 season 服务触发）
    SEASON = {
        START = "season.start",
        SETTLE = "season.settle",
        END = "season.end",
        STAGE_CHANGE = "season.stage_change",
    },

    -- 全局定时器（由 event 服务 timeutils 桥接触发）
    TIMER = {
        MINUTE = "timer.minute",
        HOUR = "timer.hour",
        DAY_RESET = "timer.day_reset",
    },
}

return event_def
