local skynet = require "skynet"
local memory = require "skynet.memory"
local tableUtils = require "utils.tableUtils"
local log = require "log"

local CMD = {}

-- 计算表的大小（近似值）
local function calculate_table_size(t, visited)
    if type(t) ~= "table" then
        return 0
    end
    
    visited = visited or {}
    if visited[t] then
        return 0
    end
    visited[t] = true
    
    local size = 0
    -- 表头的基本开销（保守估计）
    size = size + 40  -- 基础结构体大小
    
    -- 计算所有键值对的大小
    for k, v in pairs(t) do
        -- 键的大小
        if type(k) == "string" then
            size = size + #k + 8  -- 字符串开销 + 指针
        else
            size = size + 8       -- 假设其他类型键的开销
        end
        
        -- 值的大小
        if type(v) == "string" then
            size = size + #v + 8
        elseif type(v) == "table" then
            size = size + calculate_table_size(v, visited)
        else
            size = size + 8       -- 其他类型的近似值
        end
    end
    
    return size
end

-- 分析指定服务的内存使用情况
function CMD.analyze_service(service_addr)
    local result = skynet.call(service_addr, "debug", "MEM")
    return {
        lua_memory = result,  -- Lua分配的总内存(KB)
        c_memory = memory.current(),  -- C分配的内存
    }
end

-- 分析表的内存使用情况
function CMD.analyze_table(t)
    local size = calculate_table_size(t)
    return {
        total_size = size,
        human_readable_size = string.format("%.2f KB", size / 1024)
    }
end

-- 获取所有服务的内存使用情况
function CMD.analyze_all_services()
    local all = {}
    local services = skynet.call(".launcher", "lua", "LIST")
    
    for addr, name in pairs(services) do
        local ok, memory_info = pcall(CMD.analyze_service, addr)
        if ok then
            all[name] = {
                address = addr,
                memory = memory_info
            }
        end
    end
    
    return all
end

-- 分析指定服务中的指定全局变量
function CMD.analyze_global(service_addr, var_name)
    local ok, value = pcall(skynet.call, service_addr, "debug", "VAR", var_name)
    if not ok then
        return nil, "Failed to get variable: " .. tostring(value)
    end
    
    if type(value) ~= "table" then
        return nil, "Variable is not a table"
    end
    
    return CMD.analyze_table(value)
end

-- 生成内存报告
function CMD.generate_report()
    local report = {
        timestamp = os.date("%Y-%m-%d %H:%M:%S"),
        total_memory = memory.total(),
        services = CMD.analyze_all_services(),
        gc_count = collectgarbage("count"),
    }
    
    -- 添加系统内存信息
    local f = io.open("/proc/meminfo", "r")
    if f then
        local meminfo = {}
        for line in f:lines() do
            local name, value = line:match("([^:]+):%s+(%d+)")
            if name and value then
                meminfo[name] = tonumber(value)
            end
        end
        f:close()
        report.system_memory = meminfo
    end
    
    return report
end

-- 打印人类可读的内存报告
function CMD.print_report()
    local report = CMD.generate_report()
    local output = {
        string.format("Memory Report - %s", report.timestamp),
        string.format("Total Skynet Memory: %.2f MB", report.total_memory / (1024 * 1024)),
        string.format("Total Lua Memory: %.2f MB", report.gc_count / 1024),
        "\nService Memory Usage:"
    }
    
    -- 按内存使用量排序
    local services_list = {}
    for name, info in pairs(report.services) do
        table.insert(services_list, {
            name = name,
            info = info
        })
    end
    table.sort(services_list, function(a, b)
        return (a.info.memory.lua_memory or 0) > (b.info.memory.lua_memory or 0)
    end)
    
    -- 输出服务内存使用情况
    for _, service in ipairs(services_list) do
        local mem_info = service.info.memory
        if mem_info.lua_memory then
            table.insert(output, string.format("  %-30s: Lua: %.2f KB, C: %.2f KB",
                service.name,
                mem_info.lua_memory,
                mem_info.c_memory / 1024
            ))
        end
    end
    
    return table.concat(output, "\n")
end

skynet.start(function()
    skynet.dispatch("lua", function(session, source, cmd, ...)
        local f = CMD[cmd]
        if f then
            skynet.ret(skynet.pack(f(...)))
        else
            skynet.error("Unknown command: " .. cmd)
        end
    end)
    
    skynet.register(".memory_profiler")
end) 