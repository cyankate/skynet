local user_mgr = require "user_mgr"
local protocol_handler = require "protocol_handler"
local task_mgr = require "system.task.task_mgr"

local function on_task_accept(player_id, msg)
    local player = user_mgr.get_player_obj(player_id)
    if not player then
        protocol_handler.send_to_player(player_id, "task_accept_response", {
            result = 1,
            message = "player not found",
            task_id = tonumber(msg.task_id) or 0,
        })
        return
    end

    local task_id = tonumber(msg.task_id) or 0
    local ok, err = task_mgr.accept_task(player, task_id)
    if not ok then
        protocol_handler.send_to_player(player_id, "task_accept_response", {
            result = 1,
            message = err or "accept failed",
            task_id = task_id,
        })
        return
    end

    local ctn = player:get_ctn("task")
    local task_data = ctn and ctn:get_tasks()[task_id]
    protocol_handler.send_to_player(player_id, "task_accept_response", {
        result = 0,
        message = "ok",
        task_id = task_id,
        task = task_mgr.build_task_info(task_id, task_data),
    })
end

local function on_task_reward(player_id, msg)
    local player = user_mgr.get_player_obj(player_id)
    if not player then
        protocol_handler.send_to_player(player_id, "task_reward_response", {
            result = 1,
            message = "player not found",
            task_id = tonumber(msg.task_id) or 0,
        })
        return
    end

    local task_id = tonumber(msg.task_id) or 0
    local ok, err = task_mgr.get_task_reward(player, task_id)
    if not ok then
        protocol_handler.send_to_player(player_id, "task_reward_response", {
            result = 1,
            message = err or "reward failed",
            task_id = task_id,
        })
        return
    end

    protocol_handler.send_to_player(player_id, "task_reward_response", {
        result = 0,
        message = "ok",
        task_id = task_id,
    })
    task_mgr.notify_task_update(player, task_id)
end

return {
    task_accept = on_task_accept,
    task_reward = on_task_reward,
}
