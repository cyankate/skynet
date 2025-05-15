local skynet = require "skynet"
local log = require "log"

local M = {}

-- 包装服务启动函数
function M.wrap_service(startup_func, options)
    options = options or {}
    
    -- 返回包装后的启动函数
    return function()
        -- 创建一个标准的handler函数，用于处理所有lua消息请求
        local function message_handler(session, source, cmd, ...)
            local f = _G.CMD[cmd]
            if f then
                skynet.ret(skynet.pack(f(...)))
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