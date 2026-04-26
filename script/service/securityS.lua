
local skynet = require "skynet"
require "skynet.manager"
local service_wrapper = require "utils.service_wrapper"
local security_service = require "security.security_service"

CMD = setmetatable({}, { __index = security_service })

local function main()
    security_service.init()
end 

service_wrapper.create_service(main, {
    name = "security",
})
