--[[
    任务系统入口：读写 task 容器。
]]

local protocol_handler = require "protocol_handler"
local condition_mgr = require "system.condition_mgr"

local M = {}

local TASK_CONFIGS = {}
do
    local configs = require "config.task_config"
    for _, config in ipairs(configs) do
        TASK_CONFIGS[config.id] = config
    end
end

local function get_ctn(player)
    return player and player:get_ctn("task")
end

function M.get_task_config(task_id)
    return TASK_CONFIGS[tonumber(task_id) or task_id]
end

function M.check_condition(player, condition_type, params)
    return condition_mgr.check(player, condition_type, params)
end

function M.get_condition_value(player, condition_type, params)
    return condition_mgr.get_condition_value(player, condition_type, params)
end

function M.build_task_info(task_id, task_data)
    task_id = tonumber(task_id) or 0
    if not task_data then
        return {
            task_id = task_id,
            state = 0,
            accept_time = 0,
            complete_time = 0,
            progress = {},
        }
    end

    local progress = {}
    for key, value in pairs(task_data.progress or {}) do
        progress[#progress + 1] = {
            id = tostring(key),
            value = tonumber(value) or 0,
        }
    end

    return {
        task_id = task_id,
        state = tonumber(task_data.state) or 0,
        accept_time = tonumber(task_data.accept_time) or 0,
        complete_time = tonumber(task_data.complete_time) or 0,
        progress = progress,
    }
end

function M.build_sync_list(player)
    local ctn = get_ctn(player)
    if not ctn then
        return {}
    end

    local list = {}
    for task_id, task_data in pairs(ctn:get_tasks()) do
        list[#list + 1] = M.build_task_info(task_id, task_data)
    end
    for task_id, task_data in pairs(ctn:get_completed_tasks()) do
        list[#list + 1] = M.build_task_info(task_id, task_data)
    end
    table.sort(list, function(a, b)
        return a.task_id < b.task_id
    end)
    return list
end

function M.sync_to_client(player)
    if not player or not player.player_id_ then
        return false
    end
    protocol_handler.send_to_player(player.player_id_, "task_info_notify", {
        tasks = M.build_sync_list(player),
    })
    return true
end

function M.notify_task_update(player, task_id)
    if not player or not player.player_id_ then
        return false
    end
    local ctn = get_ctn(player)
    if not ctn then
        return false
    end

    task_id = tonumber(task_id)
    local task_data = ctn:get_tasks()[task_id] or ctn:get_completed_tasks()[task_id]
    if not task_data then
        return false
    end

    protocol_handler.send_to_player(player.player_id_, "task_update_notify", {
        task = M.build_task_info(task_id, task_data),
    })
    return true
end

function M.on_player_loaded(player)
    local ctn = get_ctn(player)
    if not ctn then
        return false
    end
    ctn:on_player_loaded(player)
    return true
end

function M.accept_task(player, task_id)
    local ctn = get_ctn(player)
    if not ctn then
        return false, "task container not found"
    end
    return ctn:accept_task(player, task_id)
end

function M.get_task_reward(player, task_id)
    local ctn = get_ctn(player)
    if not ctn then
        return false, "task container not found"
    end
    return ctn:get_task_reward(player, task_id)
end

function M.is_task_completed(player, task_id)
    local ctn = get_ctn(player)
    if not ctn then
        return false
    end
    return ctn:is_task_completed(task_id)
end

return M
