local bootstrap = require "entry._bootstrap"

local agent_id = tonumber(...) or 0
bootstrap("service.agent_service", {
    register_hotfix = false,
    logging_name = "agent." .. agent_id,
})
