-- 匹配规则配置（仅匹配相关）
-- 只维护“如何匹配”，不维护“如何创建副本/如何结算”。

return {
    -- 单人玩法：直进副本，不走匹配
    single = {
        entry = "direct",
        max_team_size = 1,
    },
    -- 基础多人玩法：固定5人
    multi = {
        entry = "match",
        max_team_size = 2,
    },
    -- 小队副本：固定5人，队长开本
    raid_5 = {
        entry = "match",
        max_team_size = 5,
    },
    -- 团队副本：固定10人，全员准备
    raid_10 = {
        entry = "match",
        max_team_size = 10,
    },
    -- 世界Boss模板玩法：默认 20 人
    world_boss = {
        entry = "match",
        max_team_size = 20,
    },
}
