local skynet = require "skynet"

local CMD = {}

-- 显示帮助信息
function CMD.help()
    return [[
热更新系统命令:
  update <service> <file> [args...]  - 对指定服务应用热更新文件
  update_all <file> [args...]        - 对所有已注册服务应用热更新文件
  status [service]                   - 查看热更新状态
  list                               - 列出可用的热更新模块
  stats                              - 显示热更新统计信息

]]
end

-- 对指定服务应用热更新
function CMD.update(service_name, hotfix_name, ...)
    if not service_name or not hotfix_name then
        return "用法: update <service> <file> [args...]"
    end
    
    -- 使用热更新服务
    local hotfix_service = skynet.localname(".hotfix")
    if not hotfix_service then
        return "错误: 热更新服务未启动"
    end
    
    local ok, res, err = pcall(skynet.call, hotfix_service, "lua", "apply_update", service_name, hotfix_name, ...)
    if not ok then
        return string.format("错误: 调用热更新服务失败: %s", res)
    end
    
    if res then
        return string.format("成功: 服务 %s 应用热更新 %s", service_name, hotfix_name)
    else
        return string.format("失败: 服务 %s 应用热更新 %s: %s", service_name, hotfix_name, err or "未知错误")
    end
end

-- 对所有服务应用热更新
function CMD.update_all(hotfix_name, ...)
    if not hotfix_name then
        return "用法: update_all <file> [args...]"
    end
    
    -- 使用热更新服务
    local hotfix_service = skynet.localname(".hotfix")
    if not hotfix_service then
        return "错误: 热更新服务未启动"
    end
    
    -- 使用"all"标记表示更新所有已注册服务
    local ok, result = skynet.call(hotfix_service, "lua", "batch_update", {"all"}, hotfix_name, ...)
    if not ok then
        return string.format("错误: 调用热更新服务失败:")
    end
    
    -- 生成结果报告
    local success_count = 0
    local total_count = 0
    
    for _, info in pairs(result) do
        total_count = total_count + 1
        if info.success then
            success_count = success_count + 1
        end
    end
    
    local report = string.format("热更新 %s 应用结果: %d/%d 个服务成功\n", 
                                hotfix_name, success_count, total_count)
    
    -- 添加失败的服务信息（如果有）
    if success_count < total_count then
        report = report .. "失败的服务:\n"
        for service_name, info in pairs(result) do
            if not info.success then
                report = report .. string.format("  %s: %s\n", service_name, info.result or "未知错误")
            end
        end
    end
    
    return report
end

-- 查看热更新状态
function CMD.status(service_name)
    -- 使用热更新服务
    local hotfix_service = skynet.localname(".hotfix")
    if not hotfix_service then
        return "错误: 热更新服务未启动"
    end
    
    if service_name then
        local status = skynet.call(hotfix_service, "lua", "check_status", service_name)
        return string.format("服务 %s 热更新状态: %s, 最后更新时间: %s", 
                           service_name, 
                           status.status,
                           status.last_update > 0 and os.date("%Y-%m-%d %H:%M:%S", status.last_update) or "从未")
    else
        -- 获取所有服务的状态
        local all_status = skynet.call(hotfix_service, "lua", "check_status")
        if not next(all_status) then
            return "目前没有任何服务进行过热更新"
        end
        
        local status_lines = {"所有服务的热更新状态:"}
        for service_name, status in pairs(all_status) do
            table.insert(status_lines, string.format("  %s: %s, 最后更新: %s", 
                service_name, 
                status.status,
                status.last_update > 0 and os.date("%Y-%m-%d %H:%M:%S", status.last_update) or "从未"))
        end
        
        return table.concat(status_lines, "\n")
    end
end

-- 列出可用的热更新模块
function CMD.list()
    -- 使用热更新服务
    local hotfix_service = skynet.localname(".hotfix")
    if not hotfix_service then
        return "错误: 热更新服务未启动"
    end
    
    local modules = skynet.call(hotfix_service, "lua", "list_modules")
    
    if #modules == 0 then
        return "没有找到可用的热更新模块"
    end
    
    return "可用的热更新模块:\n  " .. table.concat(modules, "\n  ")
end

-- 显示热更新统计信息
function CMD.stats()
    -- 使用热更新服务
    local hotfix_service = skynet.localname(".hotfix")
    if not hotfix_service then
        return "错误: 热更新服务未启动"
    end
    
    local stats = skynet.call(hotfix_service, "lua", "get_statistics")
    
    local lines = {"热更新统计信息:"}
    table.insert(lines, string.format("  已注册服务数: %d", stats.registered_count))
    
    if stats.total_updates == 0 then
        table.insert(lines, "  尚未执行任何热更新操作")
        return table.concat(lines, "\n")
    end
    
    table.insert(lines, string.format("  总更新次数: %d", stats.total_updates))
    table.insert(lines, string.format("  成功次数: %d (%.1f%%)", 
        stats.successful_updates, 
        stats.total_updates > 0 and (stats.successful_updates / stats.total_updates * 100) or 0))
    table.insert(lines, string.format("  失败次数: %d (%.1f%%)", 
        stats.failed_updates, 
        stats.total_updates > 0 and (stats.failed_updates / stats.total_updates * 100) or 0))
    
    -- 显示各服务的更新次数
    if next(stats.services) then
        table.insert(lines, "\n各服务热更新次数:")
        for service_name, count in pairs(stats.services) do
            table.insert(lines, string.format("  %s: %d", service_name, count))
        end
    end
    
    return table.concat(lines, "\n")
end

-- 列出所有已注册的服务
function CMD.registered()
    -- 使用热更新服务
    local hotfix_service = skynet.localname(".hotfix")
    if not hotfix_service then
        return "错误: 热更新服务未启动"
    end
    
    local services = skynet.call(hotfix_service, "lua", "get_registered_services")
    
    if not next(services) then
        return "目前没有任何已注册的服务"
    end
    
    local lines = {"已注册的服务:"}
    for name, info in pairs(services) do
        table.insert(lines, string.format("  %s (类型: %s, 注册时间: %s)", 
            name, 
            info.type, 
            os.date("%Y-%m-%d %H:%M:%S", info.register_time)))
    end
    
    return table.concat(lines, "\n")
end

return CMD 