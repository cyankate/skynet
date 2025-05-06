
package.path = package.path .. ";./script/?.lua;./script/utils/?.lua"

local skynet = require "skynet"
local log = require "log"
require "skynet.manager"

skynet.start(function()
    log.info("server start")
    local db = skynet.newservice("dbS")
    skynet.uniqueservice("protoloader")
    local gate = skynet.newservice("gateS")
    skynet.name(".gate", gate)
    skynet.call(gate, "lua", "open", {
        address = "0.0.0.0",
        port = 8888,
    })
    local event = skynet.newservice("eventS")
    skynet.name(".event", event)
    
    local login = skynet.newservice("loginS")
    skynet.name(".login", login)
    local rank = skynet.newservice("rankS")
    skynet.name(".rank", rank)
    local guild = skynet.newservice("guildS")
    skynet.name(".guild", guild)
    local match = skynet.newservice("matchS")
    skynet.name(".match", match)
    -- local season = skynet.newservice("seasonS")
    -- skynet.name(".season", season)
    local chat = skynet.newservice("chatS")
    skynet.name(".chat", chat)
    
    skynet.exit()
end)