local skynet = require "skynet"
local service_wrapper = require "utils.service_wrapper"
local season_service = require "season.season_service"

CMD = setmetatable({}, { __index = season_service })

local function main()
    CMD.init()
end

service_wrapper.create_service(main, {
    name = "season",
})
