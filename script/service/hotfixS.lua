local skynet = require "skynet"
require "skynet.manager"
local service_wrapper = require "utils.service_wrapper"
local hotfix_service = require "hotfix.hotfix_service"

CMD = setmetatable({}, { __index = hotfix_service })

-- 服务主函数
local function main()
    hotfix_service.init()
end

service_wrapper.create_service(main, {
    name = "hotfix",
    register_hotfix = false,
}) 