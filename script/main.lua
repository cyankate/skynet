
package.path = package.path .. ";./script/?.lua;./script/utils/?.lua"

local skynet = require "skynet"
local log = require "log"
require "skynet.manager"

skynet.start(function()
    log.info("server start")
    local db = skynet.newservice("db")
    skynet.uniqueservice("protoloader")
    local gate = skynet.newservice("gate")
    skynet.name(".gate", gate)
    skynet.call(gate, "lua", "open", {
        address = "0.0.0.0",
        port = 8888,
    })
    local login = skynet.newservice("login")
    skynet.name(".login", login)
    local rank = skynet.newservice("rank")
    skynet.name(".rank", rank)
    local guild = skynet.newservice("guild")
    skynet.name(".guild", guild)
    local event = skynet.newservice("event")
    skynet.name(".event", event)
    skynet.exit()
end)