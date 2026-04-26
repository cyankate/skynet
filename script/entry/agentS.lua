local service_wrapper = require "utils.service_wrapper"
local S = require "service.agent_service"

local agent_id = tonumber(...)
CMD = setmetatable({}, { __index = S })

local function main()
    if S.init then
        S.init()
    end
end

service_wrapper.create_service(main, {
    register_hotfix = false,
    logging_name = "agent." .. agent_id,
})
