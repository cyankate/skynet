local skynet = require "skynet"
local log = require "log"
require "skynet.manager"
local service_wrapper = require "utils.service_wrapper"

-- 存储各个服务的热更新状态
local hotfix_status = {}

-- 记录已加载的热更新模块
local loaded_modules = {}

-- 已注册的可热更新服务
local registered_services = {}

-- 初始化热更新模块列表
local function init_modules()
    -- 预定义常用的热更新模块
    loaded_modules = {
        "sample_hotfix",  -- 样例热更新
        "example"         -- 示例热更新
    }
    
    -- 在这里可以动态扫描hotfix目录或从配置文件加载更多模块
end

-- 记录热更新状态
local function record_status(service_name, success, result, error_msg)
    hotfix_status[service_name] = {
        last_update = skynet.time(),
        status = success and "成功" or "失败",
        result = result,
        error = error_msg
    }
    
    -- 记录日志
    if success then
        log.info("服务 %s 热更新成功: %s", service_name, result or "")
    else
        log.error("服务 %s 热更新失败: %s", service_name, error_msg or "未知错误")
    end
end

-- 检查服务是否已注册
local function is_service_registered(service_name)
    return registered_services[service_name] ~= nil
end

-- 注册服务为可热更新服务
function CMD.register(service_name, service_type)
    if not service_name then
        return false, "服务名不能为空"
    end
    
    -- 标准化服务名称
    local std_name = service_name
    if service_name:sub(1,1) == "." then
        std_name = service_name:sub(2)
    end
    
    -- 检查服务是否存在
    local target_addr = service_name
    if service_name:sub(1,1) ~= ":" and service_name:sub(1,1) ~= "." then
        target_addr = "." .. service_name
    end
    
    local handle = skynet.localname(target_addr)
    if not handle then
        return false, string.format("服务 %s 不存在", service_name)
    end
    
    -- 注册服务
    registered_services[std_name] = {
        full_name = target_addr,
        handle = handle,
        register_time = skynet.time()
    }
    
    --log.info("服务 %s 已注册为可热更新服务", std_name)
    return true
end

-- 取消注册
function CMD.unregister(service_name)
    if not service_name then
        return false, "服务名不能为空"
    end
    
    -- 标准化服务名称
    local std_name = service_name
    if service_name:sub(1,1) == "." then
        std_name = service_name:sub(2)
    end
    
    if not registered_services[std_name] then
        return false, string.format("服务 %s 未注册", std_name)
    end
    
    registered_services[std_name] = nil
    log.info("服务 %s 已取消注册", std_name)
    return true
end

-- 获取已注册的服务列表
function CMD.get_registered_services()
    local result = {}
    for name, info in pairs(registered_services) do
        result[name] = {
            register_time = info.register_time
        }
    end
    return result
end

-- 检查热更新状态
function CMD.check_status(service_name)
    if service_name then
        return hotfix_status[service_name] or { last_update = 0, status = "未更新" }
    else
        -- 返回所有服务的状态
        return hotfix_status
    end
end

-- 列出所有已注册的热更新模块
function CMD.list_modules()
    return loaded_modules
end

-- 验证服务存在性和注册状态
local function verify_service(service_name)
    -- 标准化服务名称
    local std_name = service_name
    if service_name:sub(1,1) == "." then
        std_name = service_name:sub(2)
    end
    
    -- 检查服务是否已注册
    if not registered_services[std_name] then
        return false, string.format("服务 %s 未注册，不能进行热更新", std_name)
    end
    
    -- 检查服务是否仍然存在
    local info = registered_services[std_name]
    local handle = skynet.localname(info.full_name)
    if not handle then
        -- 服务已不存在，清理注册信息
        registered_services[std_name] = nil
        return false, string.format("服务 %s 不存在或已退出", std_name)
    end
    
    return true, handle
end

-- 对特定服务执行热更新
function CMD.apply_update(service_name, module_name, ...)
    if not service_name or not module_name then
        return false, "服务名和模块名不能为空"
    end
    
    -- 标准化服务名称
    local std_name = service_name
    if service_name:sub(1,1) == "." then
        std_name = service_name:sub(2)
    end
    
    -- 验证服务注册状态
    local service_ok, service_handle = verify_service(std_name)
    if not service_ok then
        return false, service_handle
    end
    
    -- 验证模块存在
    local found = false
    for _, name in ipairs(loaded_modules) do
        if name == module_name then
            found = true
            break
        end
    end
    
    if not found then
        -- 尝试动态加载模块
        local module_path = "hotfix." .. module_name
        local ok, _ = pcall(require, module_path)
        if not ok then
            return false, string.format("热更新模块 %s 不存在或无法加载", module_name)
        else
            -- 添加到已知模块列表
            table.insert(loaded_modules, module_name)
        end
    end
    
    -- 获取服务完整地址
    local target_addr = registered_services[std_name].full_name
    
    -- 执行热更新
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

-- 批量热更新
function CMD.batch_update(services, module_name, ...)
    if type(services) ~= "table" then
        return false, "服务列表必须是一个表"
    end
    
    local results = {}
    local all_success = true
    
    -- 如果参数是"all"，则对所有已注册的服务执行热更新
    if services[1] == "all" then
        local registered = {}
        for name, _ in pairs(registered_services) do
            table.insert(registered, name)
        end
        services = registered
    end
    
    -- 只对已注册的服务执行热更新
    local valid_services = {}
    for _, service_name in ipairs(services) do
        -- 标准化服务名称
        local std_name = service_name
        if service_name:sub(1,1) == "." then
            std_name = service_name:sub(2)
        end
        
        if registered_services[std_name] then
            table.insert(valid_services, std_name)
        else
            results[std_name] = {
                success = false,
                result = "服务未注册"
            }
            all_success = false
        end
    end
    
    for _, service_name in ipairs(valid_services) do
        local ok, result = CMD.apply_update(service_name, module_name, ...)
        results[service_name] = {
            success = ok,
            result = result
        }
        
        if not ok then
            all_success = false
        end
    end
    
    return all_success, results
end

-- 获取热更新统计信息
function CMD.get_statistics()
    local stats = {
        total_updates = 0,
        successful_updates = 0,
        failed_updates = 0,
        services = {},
        registered_count = 0
    }
    
    -- 添加注册服务数量
    stats.registered_count = 0
    for _ in pairs(registered_services) do
        stats.registered_count = stats.registered_count + 1
    end
    
    for service_name, status in pairs(hotfix_status) do
        stats.total_updates = stats.total_updates + 1
        if status.status == "成功" then
            stats.successful_updates = stats.successful_updates + 1
        else
            stats.failed_updates = stats.failed_updates + 1
        end
        
        -- 收集每个服务的更新次数
        if not stats.services[service_name] then
            stats.services[service_name] = 1
        else
            stats.services[service_name] = stats.services[service_name] + 1
        end
    end
    
    return stats
end

-- 批量注册服务接口
function CMD.register_services(service_list)
    if type(service_list) ~= "table" then
        return false, "参数必须是服务名列表"
    end
    
    local results = {}
    local success_count = 0
    
    for _, service_name in ipairs(service_list) do
        local ok, result = CMD.register(service_name)
        results[service_name] = {
            success = ok,
            result = result
        }
        
        if ok then
            success_count = success_count + 1
        end
    end
    
    return true, {success_count = success_count, total = #service_list, details = results}
end

-- 服务主函数
local function main()
    -- 初始化模块列表
    init_modules()
end

service_wrapper.create_service(main, {
    name = "hotfix",
    register_hotfix = false,
}) 