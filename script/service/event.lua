package.path = package.path .. ";./script/?.lua;./script/utils/?.lua"
local skynet = require "skynet"
local log = require "log"
local event_def = require "event_def"

local event = {}

-- 事件订阅表
local subscribers = {
    player = {},    -- 玩家专属事件订阅
    global = {}     -- 全局事件订阅
}

-- 注册事件监听
function event.subscribe(event_name, service_address, player_id)
    -- 判断是玩家事件还是全局事件
    local is_global = false
    for _, global_event in pairs(event_def.GLOBAL) do
        if event_name == global_event then
            is_global = true
            break
        end
    end
    
    if is_global then
        -- 全局事件订阅
        if not subscribers.global[event_name] then
            subscribers.global[event_name] = {}
        end
        table.insert(subscribers.global[event_name], service_address)
    else
        -- 玩家专属事件订阅
        if not subscribers.player[event_name] then
            subscribers.player[event_name] = {}
        end
        if not subscribers.player[event_name][player_id] then
            subscribers.player[event_name][player_id] = {}
        end
        table.insert(subscribers.player[event_name][player_id], service_address)
    end
end

-- 取消事件监听
function event.unsubscribe(event_name, service_address, player_id)
    -- 判断是玩家事件还是全局事件
    local is_global = false
    for _, global_event in pairs(event_def.GLOBAL) do
        if event_name == global_event then
            is_global = true
            break
        end
    end
    
    if is_global then
        -- 取消全局事件订阅
        if subscribers.global[event_name] then
            for i, addr in ipairs(subscribers.global[event_name]) do
                if addr == service_address then
                    table.remove(subscribers.global[event_name], i)
                    break
                end
            end
        end
    else
        -- 取消玩家专属事件订阅
        if subscribers.player[event_name] and subscribers.player[event_name][player_id] then
            for i, addr in ipairs(subscribers.player[event_name][player_id]) do
                if addr == service_address then
                    table.remove(subscribers.player[event_name][player_id], i)
                    break
                end
            end
        end
    end
end

-- 触发玩家专属事件
function event.trigger(event_name, player_id, ...)
    if subscribers.player[event_name] and subscribers.player[event_name][player_id] then
        for _, addr in ipairs(subscribers.player[event_name][player_id]) do
            skynet.send(addr, "lua", "on_event", event_name, player_id, ...)
        end
    end
end

-- 触发全局事件
function event.trigger_global(event_name, ...)
    if subscribers.global[event_name] then
        for _, addr in ipairs(subscribers.global[event_name]) do
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