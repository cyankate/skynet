local skynet = require "skynet"
local service_wrapper = require "utils.service_wrapper"
local guild_service = require "guild.guild_service"

CMD = setmetatable({}, { __index = guild_service })

local function main()
    CMD.init()
end

service_wrapper.create_service(main, {
    name = "guild",
})
