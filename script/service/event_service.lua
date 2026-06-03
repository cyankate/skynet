local skynet = require "skynet"
local service_ctx = require "runtime.service_ctx"
local timeutils = require "utils.timeutils"
local event_def = require "define.event_def"

local M = service_ctx.get("event.event_service", {})
M.subscribers = M.subscribers or {}
local subscribers = M.subscribers

function M.subscribe(event_name, service_address)
    if not subscribers[event_name] then
        subscribers[event_name] = {}
    end
    table.insert(subscribers[event_name], service_address)
end

function M.unsubscribe(event_name, service_address)
    if subscribers[event_name] then
        for i, addr in ipairs(subscribers[event_name]) do
            if addr == service_address then
                table.remove(subscribers[event_name], i)
                break
            end
        end
    end
end

function M.trigger(event_name, ...)
    if subscribers[event_name] then
        for _, addr in ipairs(subscribers[event_name]) do
            skynet.send(addr, "lua", "on_event", event_name, ...)
        end
    end
end

local function bind_global_timers()
    timeutils.on_minute(function(ts)
        M.trigger(event_def.TIMER.MINUTE, ts)
    end)
    timeutils.on_hour(function(ts)
        M.trigger(event_def.TIMER.HOUR, ts)
    end)
    timeutils.on_day_reset(function(reset_day_key, ts)
        M.trigger(event_def.TIMER.DAY_RESET, reset_day_key, ts)
    end)
end

function M.init()
    if M._inited then
        return true
    end
    M._inited = true
    bind_global_timers()
    timeutils.start_global_timers()
    return true
end

return M
