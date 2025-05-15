
local skynet = require "skynet"
local log = require "log"
local event_def = require "define/event_def"
require "skynet.manager"
local service_wrapper = require "utils.service_wrapper"

-- 事件订阅表
local subscribers = {}

-- 注册事件监听
function CMD.subscribe(event_name, service_address)
    if not subscribers[event_name] then
        subscribers[event_name] = {}
    end
    table.insert(subscribers[event_name], service_address)
end

-- 取消事件监听
function CMD.unsubscribe(event_name, service_address)
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
function CMD.trigger(event_name, ...)
    if subscribers[event_name] then
        for _, addr in ipairs(subscribers[event_name]) do
            skynet.send(addr, "lua", "on_event", event_name, ...)
        end
    end
end

-- 主服务函数
local function main()
    
    -- 注册服务名
    skynet.register(".event")
    
    log.info("Event service started")
end

service_wrapper.create_service(main, {
    name = "event",
})