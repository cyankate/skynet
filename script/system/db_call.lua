-- DB 调用统一超时封装：dbS 卡死时不把调用方一起拖死。
-- 返回与 skynet.call 类似（只保留前两个返回值）；超时返回 nil。
local skynet = require "skynet"
local rpc = require "cluster.rpc"

local M = {}
local DEFAULT_TIMEOUT = 1000 -- 10 秒

function M.address()
    return skynet.localname(".db")
end

function M.timeout_cs()
    return DEFAULT_TIMEOUT
end

function M.call(method, ...)
    local db = M.address()
    if not db then
        return nil
    end
    local completed, ret1, ret2 = rpc.call_timeout(db, DEFAULT_TIMEOUT, method, ...)
    if not completed then
        return nil
    end
    return ret1, ret2
end

return M
