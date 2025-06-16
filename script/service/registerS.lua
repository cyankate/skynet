local skynet = require "skynet"
local service_wrapper = require "service_wrapper"
local log = require "log"

local player_id2agent = {}
function CMD.register(player_id, agent)
    player_id2agent[player_id] = agent
end 

function CMD.unregister(player_id)
    player_id2agent[player_id] = nil
end

function CMD.get_agent(player_id)
    return player_id2agent[player_id]
end

local function main()
    
end

service_wrapper.create_service(main, {
    name = "register",
})
