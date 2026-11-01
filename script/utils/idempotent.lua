-- 简单的进程内幂等去重：同一个 key 在 TTL 内只执行一次，重试返回首次结果。
-- 同时处理“执行中又来一次”的情况：后来的请求等待首次完成，不会重复执行。
local skynet = require "skynet"

local M = {}
local store = {}
local pending = {}
local TTL = 30000 -- 5 分钟（skynet 时间单位 0.01 秒）

local function cached(key)
    local item = store[key]
    if item and skynet.now() - item.ts < TTL then
        return true, item.result
    end
    return false
end

function M.run(key, fn)
    if not key then
        return fn()
    end
    local hit, result = cached(key)
    if hit then
        return table.unpack(result, 1, result.n)
    end
    local p = pending[key]
    if not p then
        p = { waiters = {} }
        pending[key] = p
        local call = table.pack(pcall(fn))
        pending[key] = nil
        if call[1] then
            local r = table.pack(table.unpack(call, 2, call.n))
            store[key] = { ts = skynet.now(), result = r }
            for _, co in ipairs(p.waiters) do
                skynet.wakeup(co)
            end
            return table.unpack(r, 1, r.n)
        end
        for _, co in ipairs(p.waiters) do
            skynet.wakeup(co)
        end
        error(call[2], 0)
    end
    -- 同一个 key 正在执行：等它完成后再取结果
    local co = coroutine.running()
    p.waiters[#p.waiters + 1] = co
    skynet.wait(co)
    hit, result = cached(key)
    if hit then
        return table.unpack(result, 1, result.n)
    end
    return M.run(key, fn)
end

function M.prune()
    local now = skynet.now()
    for key, item in pairs(store) do
        if now - item.ts >= TTL then
            store[key] = nil
        end
    end
end

return M
