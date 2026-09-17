local protocol_handler = {}
local skynet = require "skynet"
local log = require "log"
local rpc = require "cluster.rpc"

function protocol_handler.send_to_client(fd, name, data)
    local gate = rpc.local_gate()
    if not gate then
        log.error("Gate service not available")
        return false
    end
    return skynet.call(gate, "lua", "send_to_client", fd, name, data)
end

-- 发送消息给指定玩家（按玩家所在 gate；standalone 即本机 .gate）
function protocol_handler.send_to_player(player_id, name, data)
    local gate = rpc.player_gate(player_id)
    if not gate then
        log.error("Gate service not available")
        return false
    end
    return skynet.send(gate, "lua", "send_to_player", player_id, name, data)
end

-- 批量发送消息给多个玩家（可能落在不同 gate，按人拆）
function protocol_handler.send_to_players(player_ids, name, data)
    if type(player_ids) ~= "table" then
        return false
    end
    local grouped = {}
    for _, player_id in ipairs(player_ids) do
        local gate = rpc.player_gate(player_id)
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
    local registerS = rpc.named_addr(".register")
    if not registerS then
        log.error("Register service not available")
        return false
    end
    local agent = skynet.call(registerS, "lua", "get_agent", player_id)
    if not agent then
        log.error("Agent not found for player %s", player_id)
        return false
    end
    return skynet.call(agent, "lua", name, data)
end

function protocol_handler.send_to_agent(player_id, name, data)
    local registerS = rpc.named_addr(".register")
    if not registerS then
        log.error("Register service not available")
        return false
    end
    local agent = skynet.call(registerS, "lua", "get_agent", player_id)
    if not agent then
        log.error("Agent not found for player %s", player_id)
        return false
    end
    return skynet.send(agent, "lua", name, data)
end

-- 广播消息给所有在线玩家（第 4 步需扫全部 gate；现在只有本机）
function protocol_handler.broadcast(name, data)
    local gate = rpc.local_gate()
    if not gate then
        log.error("Gate service not available")
        return false
    end
    return skynet.call(gate, "lua", "broadcast_message", name, data)
end

function protocol_handler.rpc_response(fd, session, data)
    local gate = rpc.local_gate()
    if not gate then
        log.error("Gate service not available")
        return false
    end
    return skynet.call(gate, "lua", "rpc_response", fd, session, data)
end

return protocol_handler
