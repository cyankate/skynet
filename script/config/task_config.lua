-- 任务配置
-- conditions:
--   id          任务内进度键
--   type        条件类型，见 define.condition_def
--   params      条件参数
--   target      完成目标值（布尔类条件用 1）
--   count_mode  lifetime(默认) | since_accept
return {
    {
        id = 1001,
        name = "通关第一关",
        type = 1,
        require_level = 1,
        conditions = {
            {
                id = "pass_barrier_1",
                type = "barrier.pass",
                params = { barrier_no = 1 },
                target = 1,
                count_mode = "lifetime",
            },
        },
        rewards = {
            { type = "item", id = 802, count = 50 },
        },
    },
    {
        id = 1002,
        name = "车头达到2级",
        type = 1,
        pre_tasks = { 1001 },
        require_level = 1,
        conditions = {
            {
                id = "reach_level_2",
                type = "level.reach",
                params = { target_level = 2 },
                target = 2,
                count_mode = "lifetime",
            },
        },
        rewards = {
            { type = "exp", value = 100 },
        },
    },
    {
        id = 1003,
        name = "累计获得2件蓝色及以上武器",
        type = 2,
        require_level = 1,
        conditions = {
            {
                id = "weapon_blue_2",
                type = "equip.quality_gte_count",
                params = { min_quality = 3 },
                target = 2,
                count_mode = "lifetime",
            },
        },
        rewards = {
            { type = "item", id = 802, count = 100 },
        },
    },
    {
        id = 1004,
        name = "接取后再解锁1把武器",
        type = 2,
        require_level = 1,
        conditions = {
            {
                id = "weapon_after_accept",
                type = "equip.quality_gte_count",
                params = { min_quality = 1 },
                target = 1,
                count_mode = "since_accept",
            },
        },
        rewards = {
            { type = "item", id = 803, count = 1 },
        },
    },
}
