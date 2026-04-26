local service_wrapper = require "utils.service_wrapper"
local instance_service = require "instance.instance_service"

CMD = setmetatable({}, { __index = instance_service })

local function main()
    CMD.init()
end

service_wrapper.create_service(main, {
    name = "instance",
})
