local register_service = require "register.register_service"

CMD = setmetatable({}, { __index = register_service })

local function main()
    CMD.init()
end

service_wrapper.create_service(main, {
    name = "register",
})
