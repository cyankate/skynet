-- 预加载脚本：在每个服务启动前执行，提供热更新支持
package.path = package.path .. ";./script/?.lua"
skynet = require "skynet"
log = require "log"
protocol_handler = require "protocol_handler"
service_wrapper = require "utils.service_wrapper"
require "skynet.manager"
tableUtils = require "utils.tableUtils"

_G.CMD = {
    -- 加载并执行热更新文件
    hotfix = function(hotfix_name)
        log.info("执行热更新: %s", hotfix_name)
        
        local hotfix_path = "hotfix." .. hotfix_name
        
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
}