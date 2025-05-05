-- script/task/task_event.lua
local task_event = {}

-- 任务接受事件
function task_event.on_task_accepted(player, task_id)
    -- 通知客户端
    player:send_message("task_accepted", {
        task_id = task_id,
        task_data = player.task_mgr.tasks[task_id]
    })
end

-- 任务完成事件
function task_event.on_task_completed(player, task_id)
    -- 通知客户端
    player:send_message("task_completed", {
        task_id = task_id
    })
end

-- 任务领奖事件
function task_event.on_task_rewarded(player, task_id)
    -- 通知客户端
    player:send_message("task_rewarded", {
        task_id = task_id
    })
end

return task_event