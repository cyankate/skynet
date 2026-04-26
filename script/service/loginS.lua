local service_wrapper = require "utils.service_wrapper"
local login_service = require "login.login_service"

CMD = setmetatable({}, { __index = login_service })

local function main()
    CMD.init()
end

service_wrapper.create_service(main, {
    name = "login",
})