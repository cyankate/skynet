local skynet = require "skynet"
local log = require "log"
local class = require "utils.class"
local common = require "utils.common"

local load_lock = class("load_lock")

function load_lock:ctor(config)
    self.config = config or {
        load_timeout = 5,  -- 加载超时时间（秒）
    }
    self.loading = {}     -- 正在加载的数据 {key = {waiting = {}, loading = true, timeout = timeout}}
    self.load_timeout_count = 0  -- 加载超时次数
end

-- 获取加载锁
function load_lock:acquire(key)
    if not self.loading[key] then
        self.loading[key] = {
            waiting = {},
            loading = true,
            timeout = common.set_timeout(self.config.load_timeout * 100, function()
                self:handle_timeout(key)
            end),
        }
        return true
    end
    
    -- 如果已经在加载中，等待加载完成
    local co = coroutine.running()
    table.insert(self.loading[key].waiting, co)
    local result = skynet.wait(co)
    return false, result
end

-- 处理加载超时
function load_lock:handle_timeout(key)
    local loading_info = self.loading[key]
    if loading_info then
        -- 唤醒所有等待的协程，并传递超时错误
        for _, co in ipairs(loading_info.waiting) do
            skynet.wakeup(co, "timeout")
        end
        -- 清理加载信息
        self.loading[key] = nil
        self.load_timeout_count = self.load_timeout_count + 1
        log.error(string.format("Load timeout for key: %s", key))
    end
end

-- 释放加载锁
function load_lock:release(key, result)
    local loading_info = self.loading[key]
    if loading_info then
        -- 取消超时定时器
        if loading_info.timeout then
            loading_info.timeout()
        end
        -- 唤醒所有等待的协程
        for _, co in ipairs(loading_info.waiting) do
            skynet.wakeup(co, result)
        end
        -- 清理加载信息
        self.loading[key] = nil
    end
end

-- 获取统计信息
function load_lock:get_stats()
    local loading_count = 0
    local waiting_count = 0
    for _, info in pairs(self.loading) do
        loading_count = loading_count + 1
        waiting_count = waiting_count + #info.waiting
    end
    
    return {
        loading_count = loading_count,
        waiting_count = waiting_count,
        timeout_count = self.load_timeout_count
    }
end

return load_lock 