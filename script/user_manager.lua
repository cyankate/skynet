local skynet = require "skynet"

local M = {}

local agent_map = {}

function M.add_player(_pid, _agent)
    if agent_map[_pid] then
        return false
    end
    agent_map[_pid] = _agent
    return true
end 

function M.del_player(_pid)
    if not agent_map[_pid] then
        return false
    end
    agent_map[_pid] = nil
    return true
end

function M.get_player(_pid)
    return agent_map[_pid]
end

return M