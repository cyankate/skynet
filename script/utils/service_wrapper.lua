local skynet = require "skynet"
local log = require "log"

local M = {}

-- 统计数据结构
local function_stats = {
    calls = 0,           -- 总调用次数
    total_time = 0,      -- 总执行时间(ms)
    max_time = 0,        -- 最大执行时间(ms)
    min_time = math.huge, -- 最小执行时间(ms)
    last_rps_time = 0,   -- 上次RPS计算时间
    last_rps_count = 0,  -- 上次RPS计数
    current_rps = 0      -- 当前RPS
}

-- 重置统计
function M.reset_stats()
    function_stats = {
        calls = 0,
        total_time = 0,
        max_time = 0,
        min_time = math.huge,
        last_rps_time = 0,
        last_rps_count = 0,
        current_rps = 0
    }
end

-- 获取统计信息
function M.get_stats()
    return function_stats
end

-- 打印统计信息
function M.print_stats()
    local stats = M.get_stats()
    local avg_time = stats.calls > 0 and (stats.total_time / stats.calls) or 0
    
    log.info("=== Function Call Statistics ===")
    log.info("Calls: %d", stats.calls)
    log.info("RPS: %.2f", stats.current_rps)
    log.info("Avg Time: %.3f ms", avg_time)
    log.info("Max Time: %.3f ms", stats.max_time)
    log.info("Min Time: %.3f ms", stats.min_time)
    log.info("==============================")
end

-- 包装服务启动函数
function M.wrap_service(startup_func, options)
    options = options or {}
    
    -- 返回包装后的启动函数
    return function()
        -- 创建一个标准的handler函数，用于处理所有lua消息请求
        local function message_handler(session, source, cmd, ...)
            local start_time = skynet.now()
            local f = _G.CMD[cmd]
            if f then
                local result = {f(...)}
                local end_time = skynet.now()
                local cost_time = end_time - start_time
                
                -- 更新统计信息
                function_stats.calls = function_stats.calls + 1
                function_stats.total_time = function_stats.total_time + cost_time
                function_stats.max_time = math.max(function_stats.max_time, cost_time)
                function_stats.min_time = math.min(function_stats.min_time, cost_time)
                
                -- 计算RPS
                local current_time = skynet.now()
                if current_time - function_stats.last_rps_time >= 1000 then
                    function_stats.current_rps = function_stats.calls - function_stats.last_rps_count
                    function_stats.last_rps_time = current_time
                    function_stats.last_rps_count = function_stats.calls
                end
                
                skynet.ret(skynet.pack(table.unpack(result)))
            else
                log.error("service:%s, Unknown command: %s", options.name, cmd)
                skynet.ret(skynet.pack(false, "未知命令"))
            end
        end
        
        -- 设置统一的消息处理函数
        skynet.dispatch("lua", message_handler)
        
        -- 设置服务名
        if options.name then
            skynet.name("." .. options.name, skynet.self())
        end

        -- 调用原始启动函数
        startup_func()
        -- 尝试注册到热更新服务
        if options.register_hotfix ~= false and options.name then -- 默认启用
            skynet.timeout(100, function() -- 稍微延迟，确保服务完全初始化
                pcall(function()
                    local hotfix = skynet.localname(".hotfix")
                    if hotfix then
                        local ok, result = skynet.call(hotfix, "lua", "register", options.name)
                        if not ok then
                            log.error("注册到热更新服务失败 %s", result)
                        end
                    end
                end)
            end)
        end
    end
end

-- 快速创建支持热更新的服务
function M.create_service(startup_func, options)
    skynet.start(M.wrap_service(startup_func, options))
end

return M 