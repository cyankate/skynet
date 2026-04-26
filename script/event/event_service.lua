local skynet = require "skynet"
local service_ctx = require "runtime.service_ctx"

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

function M.init()
    if M._inited then
        return true
    end
    M._inited = true
    return true
end

return M
