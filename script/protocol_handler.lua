local protocol_handler = {}
local skynet = require "skynet"
local log = require "log"

function protocol_handler.send_to_client(fd, name, data)
    local gate = skynet.localname(".gate")
    if not gate then
        log.error("Gate service not available")
        return false
    end
    return skynet.call(gate, "lua", "send_to_client", fd, name, data)
end

-- 发送消息给指定玩家
function protocol_handler.send_to_player(player_id, name, data)
    local gate = skynet.localname(".gate")
    if not gate then
        log.error("Gate service not available")
        return false
    end
    
    -- 直接通过gate服务发送消息
    return skynet.send(gate, "lua", "send_to_player", player_id, name, data)
end

-- 批量发送消息给多个玩家
function protocol_handler.send_to_players(player_ids, name, data)
    local gate = skynet.localname(".gate")
    if not gate then
        log.error("Gate service not available")
        return false
    end
    
    -- 直接通过gate服务批量发送消息
    return skynet.call(gate, "lua", "send_to_players", player_ids, name, data)
end

function protocol_handler.call_agent(player_id, name, data)
    local registerS = skynet.localname(".register")
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
    local registerS = skynet.localname(".register")
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

-- 广播消息给所有在线玩家
function protocol_handler.broadcast(name, data)
    local gate = skynet.localname(".gate")
    if not gate then
        log.error("Gate service not available")
        return false
    end
    
    return skynet.call(gate, "lua", "broadcast_message", name, data)
end

function protocol_handler.rpc_response(fd, session, data)
    local gate = skynet.localname(".gate")
    if not gate then
        log.error("Gate service not available")
        return false
    end
    return skynet.call(gate, "lua", "rpc_response", fd, session, data)
end

return protocol_handler 