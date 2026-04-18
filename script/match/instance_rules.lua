-- 副本规则配置（仅副本相关）
-- 只维护“如何创建/进入/结算副本”，不维护匹配队列规则。

return {
    single = {
        instance_type_name = "single",
        adapter_name = "daily_instance",
        result_source = "client",
        default_inst_no = 1001,
        ready_mode = "auto",
    },
    multi = {
        instance_type_name = "multi",
        adapter_name = "daily_instance",
        result_source = "server",
        default_inst_no = 2001,
        ready_mode = "all",
    },
    raid_5 = {
        instance_type_name = "multi",
        adapter_name = "daily_instance",
        result_source = "server",
        default_inst_no = 2101,
        ready_mode = "leader",
    },
    raid_10 = {
        instance_type_name = "multi",
        adapter_name = "daily_instance",
        result_source = "server",
        default_inst_no = 2201,
        ready_mode = "all",
    },
    world_boss = {
        instance_type_name = "multi",
        adapter_name = "world_boss",
        result_source = "server",
        default_inst_no = 3001,
        ready_mode = "all",
    },
}
