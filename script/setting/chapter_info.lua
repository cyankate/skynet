-- 副本章节配置（测试数据）
-- key：章节 id

return {
    [1] = {
        id = 1,
        name = "第一章 · 新手村外",
        desc = "离开村庄，击退第一波史莱姆。",
        pre_chapter = 0,
        unlock_player_level = 1,
        recommend_power = 500,
        map_id = 101,
        energy_cost = 5,
        daily_limit = 99,
        first_clear_reward = { { item_id = 10001, count = 50 } },
        star_rewards = {
            [1] = { { item_id = 20001, count = 1 } },
            [2] = { { item_id = 10001, count = 30 } },
            [3] = { { item_id = 10001, count = 20 } },
        },
    },
    [2] = {
        id = 2,
        name = "第二章 · 幽暗小径",
        desc = "穿过树林，小心埋伏。",
        pre_chapter = 1,
        unlock_player_level = 5,
        recommend_power = 1200,
        map_id = 102,
        energy_cost = 5,
        daily_limit = 99,
        first_clear_reward = { { item_id = 10001, count = 80 } },
        star_rewards = {
            [1] = { { item_id = 20001, count = 2 } },
            [2] = { { item_id = 10001, count = 40 } },
            [3] = { { item_id = 10001, count = 25 } },
        },
    },
    [3] = {
        id = 3,
        name = "第三章 · 矿洞深处",
        desc = "深入矿洞，寻找失踪的矿工。",
        pre_chapter = 2,
        unlock_player_level = 10,
        recommend_power = 2800,
        map_id = 103,
        energy_cost = 8,
        daily_limit = 20,
        first_clear_reward = { { item_id = 30001, count = 1 } },
        star_rewards = {
            [1] = { { item_id = 30001, count = 1 } },
            [2] = { { item_id = 10001, count = 60 } },
            [3] = { { item_id = 10001, count = 35 } },
        },
    },
}
