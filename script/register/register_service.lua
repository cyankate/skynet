local service_ctx = require "runtime.service_ctx"

local M = service_ctx.get("register.register_service", {})
M.player_id2agent = M.player_id2agent or {}
local player_id2agent = M.player_id2agent

function M.register(player_id, agent)
    player_id2agent[player_id] = agent
end

function M.unregister(player_id)
    player_id2agent[player_id] = nil
end

function M.get_agent(player_id)
    return player_id2agent[player_id]
end

function M.init()
    if M._inited then
        return true
    end
    M._inited = true
    return true
end

return M
