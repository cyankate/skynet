-- 热更新示例文件：修改agent服务的Timer间隔
-- 使用方法：hotfix agent example

local skynet = require "skynet"
local log = require "log"

-- 热更新执行函数
local function update()
    log.info("执行示例热更新：修改Timer间隔")
    
    return true 
end

return {
    update = update
} 