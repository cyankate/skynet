-- 副本规则配置（仅副本相关）
-- 只维护“如何创建/进入/结算副本”，不维护匹配队列规则。

return {
    single = {
        instance_type_name = "single",
        mode_type = "survival",
        mode_config = {
            -- 生存模式默认按时间推进
            target_seconds = 180,
        },
        adapter_name = "daily_instance",
        result_source = "client",
        default_inst_no = 1001,
        ready_mode = "auto",
    },
    multi = {
        instance_type_name = "multi",
        mode_type = "waves",
        mode_config = {
            -- 车轮战默认事件驱动（wave_clear）
            auto_advance = false,
            total_waves = 5,
            wave_seconds = 25,
        },
        adapter_name = "daily_instance",
        result_source = "server",
        default_inst_no = 2001,
        ready_mode = "all",
    },
    raid_5 = {
        instance_type_name = "multi",
        mode_type = "boss_rush",
        mode_config = {
            -- 连续Boss默认事件驱动（boss_killed）
            auto_advance = false,
            total_bosses = 3,
            boss_seconds = 45,
        },
        adapter_name = "daily_instance",
        result_source = "server",
        default_inst_no = 2101,
        ready_mode = "leader",
    },
    raid_10 = {
        instance_type_name = "multi",
        mode_type = "objective",
        mode_config = {
            -- 目标制默认事件驱动（add_score / objective_failed）
            auto_advance = false,
            target_score = 120,
            gain_per_second = 6,
        },
        adapter_name = "daily_instance",
        result_source = "server",
        default_inst_no = 2201,
        ready_mode = "all",
    },
    world_boss = {
        instance_type_name = "multi",
        mode_type = "boss_rush",
        mode_config = {
            -- 世界Boss也走事件驱动
            auto_advance = false,
            total_bosses = 1,
            boss_seconds = 180,
        },
        adapter_name = "world_boss",
        result_source = "server",
        default_inst_no = 3001,
        ready_mode = "all",
    },
}
