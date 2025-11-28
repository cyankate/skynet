local skynet = require "skynet"
local log = require "log"
local tableUtils = require "utils.tableUtils"
require "skynet.manager"

skynet.start(function()
    skynet.newservice("hotfixS")
    
    skynet.uniqueservice("protoloader")

    local db = skynet.newservice("dbS")

    local redis = skynet.newservice("redisS")

    local debug_console = skynet.newservice("debug_console")
    
    local event = skynet.newservice("eventS")
    
    local security = skynet.newservice("securityS")
    
    local login = skynet.newservice("loginS")

    local rank = skynet.newservice("rankS")

    local guild = skynet.newservice("guildS")
    
    local chat = skynet.newservice("chatS")

    local http = skynet.newservice("httpS")

    local mail = skynet.newservice("mailS")

    local friend = skynet.newservice("friendS")
    
    local payment = skynet.newservice("paymentS")

    local gate = skynet.newservice("gateS")

    local match = skynet.newservice("matchS")

    local pathfinding = skynet.newservice("pathfindingS")

    local scene = skynet.newservice("sceneS")

    local register = skynet.newservice("registerS")

    skynet.call(gate, "lua", "open", {
        address = "0.0.0.0",
        port = 8888,
        maxclient = 8192,
    })

    skynet.exit()
end)