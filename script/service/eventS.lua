package.path = package.path .. ";./script/?.lua;./script/utils/?.lua"
local skynet = require "skynet"
local log = require "log"
local event_def = require "define/event_def"

local event = {}

-- 事件订阅表
local subscribers = {}

-- 注册事件监听
function event.subscribe(event_name, service_address)
    if not subscribers[event_name] then
        subscribers[event_name] = {}
    end
    --log.info(string.format("subscribe event: %s, %s", event_name, service_address))
    table.insert(subscribers[event_name], service_address)
end

-- 取消事件监听
function event.unsubscribe(event_name, service_address)
    if subscribers[event_name] then
        for i, addr in ipairs(subscribers[event_name]) do
            if addr == service_address then
                table.remove(subscribers[event_name], i)
                break
            end
        end
    end
end

-- 触发事件
function event.trigger(event_name, ...)
    if subscribers[event_name] then
        for _, addr in ipairs(subscribers[event_name]) do
            skynet.send(addr, "lua", "on_event", event_name, ...)
        end
    end
end

-- 服务启动
skynet.start(function()
    skynet.dispatch("lua", function(session, source, cmd, ...)
        local f = event[cmd]
        if f then
            skynet.ret(skynet.pack(f(...)))
        end
    end)
end)

return event