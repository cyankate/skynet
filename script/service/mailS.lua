local service_wrapper = require "utils.service_wrapper"
local mail_service = require "mail.mail_service"

CMD = setmetatable({}, { __index = mail_service })

local function main()
    CMD.init()
end

service_wrapper.create_service(main, {
    name = "mail",
})
