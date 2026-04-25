-- 物品配置（示例）
-- 约定：
-- type = 0 虚拟道具；其他为实体道具（进背包）
-- sub_type = 子类型（例如 guild_point、stamina）
return {
    -- 示例：公会积分（虚拟道具，走公会模块处理器）
    [100001] = {
        id = 100001,
        name = "公会积分",
        type = 0,
        sub_type = "guild_point",
    },
}
