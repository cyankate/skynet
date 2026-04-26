local service_wrapper = require "utils.service_wrapper"
local agent_service = require "agent.agent_service"

local agent_id = tonumber(...)
CMD = setmetatable({}, { __index = agent_service })

local function main()
    CMD.init()
end

service_wrapper.create_service(main, {
    register_hotfix = false,
    logging_name = "agent." .. agent_id,
})