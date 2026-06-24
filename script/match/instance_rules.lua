--[[
    副本规则配置。
    handler 指向业务模块（如 system.barrier_mgr），约定 hook：
    before_instance_start / on_play_start_failed / before_instance_end / after_instance_end

    before_instance_start 的 ctx 含 player_pack（player:build_instance_pack 结果），
    业务可在 hook 内修改 ctx.player_pack 或返回 join_data.player_pack 后再进本。
]]

local M = {
    barrier = {
        instance_type_name = "rogue",
        mode_type = "survival",
        mode_config = {
            target_seconds = 180,
        },
        adapter_name = "daily_instance",
        result_source = "client",
        ready_mode = "auto",
        handler = "system.barrier_mgr",
    },
    single = {
        instance_type_name = "single",
        mode_type = "survival",
        mode_config = {
            target_seconds = 180,
        },
        adapter_name = "daily_instance",
        result_source = "client",
        ready_mode = "auto",
    },
    multi = {
        instance_type_name = "multi",
        mode_type = "waves",
        mode_config = {
            auto_advance = false,
            total_waves = 5,
            wave_seconds = 25,
        },
        adapter_name = "daily_instance",
        result_source = "server",
        ready_mode = "all",
    },
    raid_5 = {
        instance_type_name = "multi",
        mode_type = "boss_rush",
        mode_config = {
            auto_advance = false,
            total_bosses = 3,
            boss_seconds = 45,
        },
        adapter_name = "daily_instance",
        result_source = "server",
        ready_mode = "leader",
    },
    raid_10 = {
        instance_type_name = "multi",
        mode_type = "objective",
        mode_config = {
            auto_advance = false,
            target_score = 120,
            gain_per_second = 6,
        },
        adapter_name = "daily_instance",
        result_source = "server",
        ready_mode = "all",
    },
    world_boss = {
        instance_type_name = "multi",
        mode_type = "boss_rush",
        mode_config = {
            auto_advance = false,
            total_bosses = 1,
            boss_seconds = 180,
        },
        adapter_name = "world_boss",
        result_source = "server",
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
