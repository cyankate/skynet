local skynet = require "skynet"
require "skynet.manager"
local service_wrapper = require "utils.service_wrapper"
local payment_service = require "payment.payment_service"

CMD = setmetatable({}, { __index = payment_service })

local function main()
    payment_service.init()
end

service_wrapper.create_service(main, {
    name = "payment",
})