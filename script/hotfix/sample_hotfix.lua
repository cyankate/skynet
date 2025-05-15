-- 热更新示例文件：用于测试热更新功能
-- 使用方法：在hotfix服务中调用 apply_update("服务名", "sample_hotfix")

local skynet = require "skynet"
local log = require "log"

-- 热更新执行函数
local function update(...)
    log.info("执行热更新测试 sample_hotfix")
    log.info("接收到参数: %s", table.concat({...}, ", "))
    
    -- 打印当前服务的CMD表
    local cmd_funcs = {}
    for k, _ in pairs(_G.CMD) do
        table.insert(cmd_funcs, k)
    end
    log.info("当前服务CMD表: %s", table.concat(cmd_funcs, ", "))
    
    -- 可以在这里修改服务的全局变量或函数
    
    return true, "热更新成功执行"
end

-- 返回模块
return {
    update = update
} 