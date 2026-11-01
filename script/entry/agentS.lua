local bootstrap = require "entry._bootstrap"

local agent_id = tonumber(...) or 0
package.loaded["agent.worker_bind"] = { agent_id = agent_id }
bootstrap("service.agent_service", {
    register_hotfix = false,
    logging_name = "agent." .. agent_id,
})
