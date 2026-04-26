local skynet = require "skynet"
local log = require "log"
local service_ctx = require "runtime.service_ctx"

local M = service_ctx.get("hotfix.hotfix_service", {})
M.hotfix_status = M.hotfix_status or {}
M.loaded_modules = M.loaded_modules or {}
M.registered_services = M.registered_services or {}
M._inited = M._inited or false

local hotfix_status = M.hotfix_status
local loaded_modules = M.loaded_modules
local registered_services = M.registered_services

local function init_modules()
    if #loaded_modules == 0 then
        loaded_modules[1] = "sample_hotfix"
        loaded_modules[2] = "example"
    end
end

local function record_status(service_name, success, result, error_msg)
    hotfix_status[service_name] = {
        last_update = skynet.time(),
        status = success and "成功" or "失败",
        result = result,
        error = error_msg,
    }
end

local function verify_service(service_name)
    local std_name = service_name
    if service_name:sub(1, 1) == "." then std_name = service_name:sub(2) end
    if not registered_services[std_name] then
        return false, string.format("服务 %s 未注册，不能进行热更新", std_name)
    end
    local info = registered_services[std_name]
    local handle = skynet.localname(info.full_name)
    if not handle then
        registered_services[std_name] = nil
        return false, string.format("服务 %s 不存在或已退出", std_name)
    end
    return true, handle
end

function M.register(service_name, service_type)
    if not service_name then return false, "服务名不能为空" end
    local std_name = service_name
    if service_name:sub(1, 1) == "." then std_name = service_name:sub(2) end
    local target_addr = service_name
    if service_name:sub(1, 1) ~= ":" and service_name:sub(1, 1) ~= "." then target_addr = "." .. service_name end
    local handle = skynet.localname(target_addr)
    if not handle then return false, string.format("服务 %s 不存在", service_name) end
    registered_services[std_name] = { full_name = target_addr, handle = handle, register_time = skynet.time() }
    return true
end

function M.unregister(service_name)
    if not service_name then return false, "服务名不能为空" end
    local std_name = service_name
    if service_name:sub(1, 1) == "." then std_name = service_name:sub(2) end
    if not registered_services[std_name] then return false, string.format("服务 %s 未注册", std_name) end
    registered_services[std_name] = nil
    return true
end

function M.get_registered_services()
    local result = {}
    for name, info in pairs(registered_services) do
        result[name] = { register_time = info.register_time }
    end
    return result
end

function M.check_status(service_name)
    if service_name then
        return hotfix_status[service_name] or { last_update = 0, status = "未更新" }
    end
    return hotfix_status
end

function M.list_modules() return loaded_modules end

function M.apply_update(service_name, module_name, ...)
    if not service_name or not module_name then return false, "服务名和模块名不能为空" end
    local std_name = service_name
    if service_name:sub(1, 1) == "." then std_name = service_name:sub(2) end
    local service_ok, service_handle = verify_service(std_name)
    if not service_ok then return false, service_handle end
    local found = false
    for _, name in ipairs(loaded_modules) do if name == module_name then found = true break end end
    if not found then
        local module_path = "hotfix." .. module_name
        local ok = pcall(require, module_path)
        if not ok then return false, string.format("热更新模块 %s 不存在或无法加载", module_name) end
        table.insert(loaded_modules, module_name)
    end
    local target_addr = registered_services[std_name].full_name
    local ok, result, err = pcall(skynet.call, target_addr, "lua", "hotfix", module_name, ...)
    if not ok then
        record_status(std_name, false, nil, tostring(result))
        return false, "发送热更新请求失败: " .. tostring(result)
    end
    if not result then
        record_status(std_name, false, nil, err or "未知错误")
        return false, err or "热更新失败"
    end
    record_status(std_name, true, result)
    return true, result
end

function M.batch_update(services, module_name, ...)
    if type(services) ~= "table" then return false, "服务列表必须是一个表" end
    local results, all_success = {}, true
    if services[1] == "all" then
        local registered = {}
        for name, _ in pairs(registered_services) do table.insert(registered, name) end
        services = registered
    end
    local valid_services = {}
    for _, service_name in ipairs(services) do
        local std_name = service_name
        if service_name:sub(1, 1) == "." then std_name = service_name:sub(2) end
        if registered_services[std_name] then
            table.insert(valid_services, std_name)
        else
            results[std_name] = { success = false, result = "服务未注册" }
            all_success = false
        end
    end
    for _, service_name in ipairs(valid_services) do
        local ok, result = M.apply_update(service_name, module_name, ...)
        results[service_name] = { success = ok, result = result }
        if not ok then all_success = false end
    end
    return all_success, results
end

function M.reload_loaded_code(service_name)
    if not service_name then return false, "服务名不能为空" end
    local std_name = service_name
    if service_name:sub(1, 1) == "." then std_name = service_name:sub(2) end
    local service_ok, service_err = verify_service(std_name)
    if not service_ok then return false, service_err end
    local target_addr = registered_services[std_name].full_name
    local ok, result, err = pcall(skynet.call, target_addr, "lua", "hotfix_reload_loaded")
    if not ok then
        record_status(std_name, false, nil, tostring(result))
        return false, "发送自动热更请求失败: " .. tostring(result)
    end
    if not result then
        record_status(std_name, false, nil, tostring(err or "未知错误"))
        return false, err or "自动热更失败"
    end
    record_status(std_name, true, "自动热更成功")
    return true, err
end

function M.reload_loaded_code_batch(services)
    if type(services) ~= "table" then return false, "服务列表必须是一个表" end
    local results, all_success = {}, true
    if services[1] == "all" then
        local registered = {}
        for name, _ in pairs(registered_services) do table.insert(registered, name) end
        services = registered
    end
    for _, service_name in ipairs(services) do
        local ok, result = M.reload_loaded_code(service_name)
        results[service_name] = { success = ok, result = result }
        if not ok then all_success = false end
    end
    return all_success, results
end

function M.get_statistics()
    local stats = { total_updates = 0, successful_updates = 0, failed_updates = 0, services = {}, registered_count = 0 }
    for _ in pairs(registered_services) do stats.registered_count = stats.registered_count + 1 end
    for service_name, status in pairs(hotfix_status) do
        stats.total_updates = stats.total_updates + 1
        if status.status == "成功" then stats.successful_updates = stats.successful_updates + 1 else stats.failed_updates = stats.failed_updates + 1 end
        stats.services[service_name] = (stats.services[service_name] or 0) + 1
    end
    return stats
end

function M.register_services(service_list)
    if type(service_list) ~= "table" then return false, "参数必须是服务名列表" end
    local results, success_count = {}, 0
    for _, service_name in ipairs(service_list) do
        local ok, result = M.register(service_name)
        results[service_name] = { success = ok, result = result }
        if ok then success_count = success_count + 1 end
    end
    return true, { success_count = success_count, total = #service_list, details = results }
end

function M.init()
    if M._inited then return end
    M._inited = true
    init_modules()
end

return M
