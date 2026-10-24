local protocol_handler = {}
local skynet = require "skynet"
local log = require "log"
local rpc = require "cluster.rpc"
local locator = require "cluster.locator"

local local_agent

function protocol_handler.set_local_agent(mod)
    local_agent = mod
end

local function get_agent(player_id)
    if local_agent and local_agent.has_player(player_id) then
        return skynet.self()
    end
    return locator.get_agent(player_id)
end

function protocol_handler.send_to_client(fd, name, data, gate)
    if not gate then
        log.error("send_to_client missing gate, fd=%s name=%s", tostring(fd), tostring(name))
        return false
    end
    return skynet.call(gate, "lua", "send_to_client", fd, name, data)
end

-- 业务下行：经 agent 转出。本进程有该玩家则直接 push，不问 locator。
function protocol_handler.send_to_player(player_id, name, data)
    local agent = get_agent(player_id)
    if not agent then
        return false
    end
    if local_agent and agent == skynet.self() then
        return local_agent.push_client(player_id, name, data)
    end
    return skynet.send(agent, "lua", "push_client", player_id, name, data)
end

-- 群发：game 上的服务一次问 locator；agent 里只可能是本进程玩家
function protocol_handler.send_to_players(player_ids, name, data)
    if type(player_ids) ~= "table" then
        return false
    end
    if local_agent then
        return local_agent.push_clients(player_ids, name, data)
    end
    local agents = locator.get_agents(player_ids)
    local grouped = {}
    for _, player_id in ipairs(player_ids) do
        local agent = agents[tonumber(player_id) or player_id]
        if agent then
            local bucket = grouped[agent]
            if not bucket then
                bucket = {}
                grouped[agent] = bucket
            end
            bucket[#bucket + 1] = player_id
        end
    end
    local any = false
    for agent, ids in pairs(grouped) do
        skynet.send(agent, "lua", "push_clients", ids, name, data)
        any = true
    end
    return any
end

-- 分片热路径：locator 查门，直推连接。无连接 = 离线/虚拟观察者，静默丢弃
function protocol_handler.send_to_conn(player_id, name, data)
    local gate = rpc.player_gate(player_id)
    if not gate then
        return false
    end
    return skynet.send(gate, "lua", "send_to_player", player_id, name, data)
end

function protocol_handler.send_to_conns(player_ids, name, data)
    if type(player_ids) ~= "table" then
        return false
    end
    local gates = rpc.player_gates(player_ids)
    local grouped = {}
    for _, player_id in ipairs(player_ids) do
        local gate = gates[tonumber(player_id) or player_id]
        if gate then
            local bucket = grouped[gate]
            if not bucket then
                bucket = {}
                grouped[gate] = bucket
            end
            bucket[#bucket + 1] = player_id
        end
    end
    local any = false
    for gate, ids in pairs(grouped) do
        skynet.send(gate, "lua", "send_to_players", ids, name, data)
        any = true
    end
    return any
end

function protocol_handler.call_agent(player_id, name, data)
    local agent = get_agent(player_id)
    if not agent then
        log.error("Agent not found for player %s", player_id)
        return false
    end
    return skynet.call(agent, "lua", name, data)
end

function protocol_handler.send_to_agent(player_id, name, data)
    local agent = get_agent(player_id)
    if not agent then
        log.error("Agent not found for player %s", player_id)
        return false
    end
    return skynet.send(agent, "lua", name, data)
end

function protocol_handler.rpc_response(fd, session, data, gate)
    if not gate then
        log.error("rpc_response missing gate, fd=%s", tostring(fd))
        return false
    end
    return skynet.call(gate, "lua", "rpc_response", fd, session, data)
end

return protocol_handler
