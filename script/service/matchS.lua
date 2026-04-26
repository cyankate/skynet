local service_wrapper = require "utils.service_wrapper"
local match_service = require "match.match_service"

CMD = setmetatable({}, { __index = match_service })

local function main()
    CMD.init()
end

service_wrapper.create_service(main, {
    name = "match",
})
