
local service_wrapper = require "utils.service_wrapper"
local event_service = require "event.event_service"

CMD = setmetatable({}, { __index = event_service })

-- 主服务函数
local function main()
    CMD.init()
end

service_wrapper.create_service(main, {
    name = "event",
})