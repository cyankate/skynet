--[[
    agent 进程内本地事件（同步 dispatch，不经过 .event 服务）。
    事件名见 define.event_def.AGENT.*
]]

local M = {}

local handlers = {}

function M.register(event_name, fn)
    assert(type(event_name) == "string" and event_name ~= "", "event_name required")
    assert(type(fn) == "function", "handler must be function")
    if not handlers[event_name] then
        handlers[event_name] = {}
    end
    handlers[event_name][#handlers[event_name] + 1] = fn
end

function M.unregister(event_name, fn)
    local list = handlers[event_name]
    if not list then
        return
    end
    for i, item in ipairs(list) do
        if item == fn then
            table.remove(list, i)
            return
        end
    end
end

function M.trigger(event_name, ...)
    local list = handlers[event_name]
    if not list then
        return
    end
    for _, fn in ipairs(list) do
        fn(...)
    end
end

return M
