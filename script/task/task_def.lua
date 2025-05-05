-- script/task/task_def.lua
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
    
    -- 任务条件类型
    CONDITION_TYPE = {
        LEVEL = 1,          -- 等级要求
        ITEM = 2,           -- 物品要求
        KILL = 3,           -- 击杀要求
        COLLECT = 4,        -- 收集要求
        TALK = 5,           -- 对话要求
        USE_ITEM = 6,       -- 使用物品
        REACH_PLACE = 7,    -- 到达地点
    },
    
    -- 任务事件类型
    EVENT_TYPE = {
        LEVEL_UP = "player.level_up",
        ITEM_CHANGE = "player.item_change",
        KILL_MONSTER = "battle.kill_monster",
        COLLECT_ITEM = "player.collect_item",
        TALK_NPC = "player.talk_npc",
        USE_ITEM = "player.use_item",
        REACH_PLACE = "player.reach_place",
    }
}

return task_def