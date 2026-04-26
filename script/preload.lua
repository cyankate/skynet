-- 预加载脚本：在每个服务启动前执行，提供热更新支持
package.path = package.path .. ";./script/?.lua"
skynet = require "skynet"
log = require "log"
local codecache = require "skynet.codecache"
protocol_handler = require "protocol_handler"
service_wrapper = require "utils.service_wrapper"
require "skynet.manager"
tableUtils = require "utils.tableUtils"

local function clear_code_cache()
    local ok, err = pcall(codecache.clear)
    if not ok then
        log.warning("codecache.clear failed: %s", tostring(err))
    end
end

_G.CMD = {
    -- 加载并执行热更新文件
    hotfix = function(hotfix_name)
        log.info("执行热更新: %s", hotfix_name)
        
        local hotfix_path = "hotfix." .. hotfix_name
        
        -- 清除代码缓存，确保读取最新源码
        clear_code_cache()

        -- 清除可能的旧缓存
        package.loaded[hotfix_path] = nil
        
        -- 加载热更新模块
        local ok, hotfix_module = pcall(require, hotfix_path)
        if not ok then
            log.error("加载热更新模块失败: %s, 错误: %s", hotfix_name, hotfix_module)
            return false, "加载失败: " .. hotfix_module
        end
        
        -- 执行热更新
        if type(hotfix_module) == "table" and type(hotfix_module.update) == "function" then
            -- 如果热更新模块提供update函数，传入参数
            log.info("执行热更新模块 %s 的update函数", hotfix_name)
            local update_ok, update_result = pcall(hotfix_module.update)
            if not update_ok then
                log.error("执行热更新失败: %s", update_result)
                return false, "执行失败: " .. update_result
            end
            
            log.info("热更新 %s 执行成功", hotfix_name)
            CMD.after_hotfix(hotfix_name)
            return true, update_result or "更新成功"
        elseif type(hotfix_module) == "function" then
            -- 如果模块直接返回函数，传入参数执行它
            log.info("执行热更新模块 %s 函数", hotfix_name)
            local update_ok, update_result = pcall(hotfix_module)
            if not update_ok then
                log.error("执行热更新失败: %s", update_result)
                return false, "执行失败: " .. update_result
            end
            
            log.info("热更新 %s 执行成功", hotfix_name)
            CMD.after_hotfix(hotfix_name)
            return true, update_result or "更新成功"
        else
            log.error("热更新模块格式不正确，需要提供update函数或直接返回函数")
            return false, "模块格式不正确"
        end
    end,

    after_hotfix = function(hotfix_name)
        --log.info("热更新后执行")
    end,

    -- 自动重载当前服务里已加载的 Lua 代码模块（仅 script 目录）
    hotfix_reload_loaded = function()
        local function is_project_lua_module(module_name)
            if type(module_name) ~= "string" then
                return false
            end
            local file_path = package.searchpath(module_name, package.path)
            if not file_path then
                return false
            end
            local normalized = file_path:gsub("\\", "/")
            return normalized:find("/script/", 1, true) ~= nil
        end

        local modules = {}
        for module_name, loaded in pairs(package.loaded) do
            if loaded ~= nil and is_project_lua_module(module_name) then
                modules[#modules + 1] = module_name
            end
        end
        table.sort(modules)

        local reloaded = {}
        local failed = {}
        local old_modules = {}
        -- 批量重载前清理一次代码缓存
        clear_code_cache()

        -- 第一阶段：统一失效（避免顺序重载时依赖引用旧模块）
        for _, module_name in ipairs(modules) do
            old_modules[module_name] = package.loaded[module_name]
            package.loaded[module_name] = nil
        end

        -- 第二阶段：统一加载
        for _, module_name in ipairs(modules) do
            local ok, result = pcall(require, module_name)
            if ok then
                reloaded[#reloaded + 1] = module_name
            else
                -- 失败时恢复旧模块，避免服务进入不可用状态
                package.loaded[module_name] = old_modules[module_name]
                failed[#failed + 1] = {
                    module = module_name,
                    error = tostring(result),
                }
            end
        end

        if #failed > 0 then
            return false, {
                total = #modules,
                reloaded = #reloaded,
                failed = failed,
            }
        end

        return true, {
            total = #modules,
            reloaded = #reloaded,
            failed = {},
        }
    end,
}