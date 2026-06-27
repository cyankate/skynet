--[[
    玩法规则（匹配 + 进本 + 结算 hook 合一）。
    entry: direct 直进 | match 走匹配
    handler: 业务模块路径，约定 before_instance_start / on_play_start_failed /
             before_instance_settle / on_instance_settled / on_instance_action
    on_instance_action: 由 instance 服务在需要时主动 call_play_agent 触发
]]

local M = {
    barrier = {
        entry = "direct",
        max_team_size = 1,
        instance_type_name = "rogue",
        mode_type = "survival",
        mode_config = {
            target_seconds = 180,
        },
        adapter_name = "daily_instance",
        ready_mode = "auto",
        handler = "system.barrier_mgr",
    },
    single = {
        entry = "direct",
        max_team_size = 1,
        instance_type_name = "single",
        mode_type = "survival",
        mode_config = {
            target_seconds = 180,
        },
        adapter_name = "daily_instance",
        ready_mode = "auto",
    },
    multi = {
        entry = "match",
        max_team_size = 2,
        instance_type_name = "multi",
        mode_type = "waves",
        mode_config = {
            auto_advance = false,
            total_waves = 5,
            wave_seconds = 25,
        },
        adapter_name = "daily_instance",
        ready_mode = "all",
    },
    raid_5 = {
        entry = "match",
        max_team_size = 5,
        instance_type_name = "multi",
        mode_type = "boss_rush",
        mode_config = {
            auto_advance = false,
            total_bosses = 3,
            boss_seconds = 45,
        },
        adapter_name = "daily_instance",
        ready_mode = "leader",
    },
    raid_10 = {
        entry = "match",
        max_team_size = 10,
        instance_type_name = "multi",
        mode_type = "objective",
        mode_config = {
            auto_advance = false,
            target_score = 120,
            gain_per_second = 6,
        },
        adapter_name = "daily_instance",
        ready_mode = "all",
    },
    world_boss = {
        entry = "match",
        max_team_size = 20,
        instance_type_name = "multi",
        mode_type = "boss_rush",
        mode_config = {
            auto_advance = false,
            total_bosses = 1,
            boss_seconds = 180,
        },
        adapter_name = "world_boss",
        ready_mode = "all",
    },
}

local handler_cache = {}

function M.get_handler(rule)
    if not rule or not rule.handler then
        return nil
    end
    local path = rule.handler
    if not handler_cache[path] then
        handler_cache[path] = require(path)
    end
    return handler_cache[path]
end

function M.call_hook(rule, hook_name, ...)
    local mod = M.get_handler(rule)
    if not mod then
        return nil
    end
    local fn = mod[hook_name]
    if not fn then
        return nil
    end
    return fn(...)
end

return M
