local service_wrapper = require "utils.service_wrapper"
local rank_service = require "rank.rank_service"

CMD = setmetatable({}, { __index = rank_service })

local function main()
    CMD.init()
end

service_wrapper.create_service(main, {
    name = "rank",
})