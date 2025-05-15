local protocol_handler = {}
local skynet = require "skynet"
local log = require "log"

-- 发送消息给指定玩家
function protocol_handler.send_to_player(player_id, name, data)
    local gate = skynet.localname(".gate")
    if not gate then
        log.error("Gate service not available")
        return false
    end
    
    -- 直接通过gate服务发送消息
    return skynet.call(gate, "lua", "send_to_player", player_id, {
        name = name,
        data = data
    })
end

-- 批量发送消息给多个玩家
function protocol_handler.send_to_players(player_ids, name, data)
    local gate = skynet.localname(".gate")
    if not gate then
        log.error("Gate service not available")
        return false
    end
    
    -- 直接通过gate服务批量发送消息
    return skynet.call(gate, "lua", "send_to_players", player_ids, {
        name = name,
        data = data
    })
end

-- 广播消息给所有在线玩家
function protocol_handler.broadcast(name, data)
    local gate = skynet.localname(".gate")
    if not gate then
        log.error("Gate service not available")
        return false
    end
    
    return skynet.call(gate, "lua", "broadcast_message", {
        name = name,
        data = data
    })
end

return protocol_handler 