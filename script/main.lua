local skynet = require "skynet"
local log = require "log"
local tableUtils = require "utils.tableUtils"
local shard = require "map.shard"
local layout = require "cluster.layout"
require "skynet.manager"

skynet.start(function()
    skynet.newservice("hotfixS")
    
    skynet.uniqueservice("protoloader")

    if layout.use_cluster() then
        local cluster = require "skynet.cluster"
        cluster.open(layout.self_node())
        log.info("cluster opened, node=%s mode=%s", layout.self_node(), layout.mode())
    end

    local db = skynet.newservice("dbS")

    local redis = skynet.newservice("redisS")

    local mongo = skynet.newservice("mongoS")

    local debug_console = skynet.newservice("debug_console")
    
    local event = skynet.newservice("eventS")
    
    local security = skynet.newservice("securityS")
    
    local login = skynet.newservice("loginS")

    local rank = skynet.newservice("rankS")

    local guild = skynet.newservice("guildS")

    local global = skynet.newservice("globalS")
    
    local chat = skynet.newservice("chatS")

    local http = skynet.newservice("httpS")

    local mail = skynet.newservice("mailS")

    local friend = skynet.newservice("friendS")
    
    local payment = skynet.newservice("paymentS")

    local gate = skynet.newservice("gateS")

    local match = skynet.newservice("matchS")

    local instance = skynet.newservice("instanceS")

    local pathfinding = skynet.newservice("pathfindingS")

    -- 全局地图服：启动后自行拉起各分片
    local map = skynet.newservice("mapS", shard.default_def().map_id)

    local register = skynet.newservice("registerS")

    skynet.call(gate, "lua", "open", {
        address = "0.0.0.0",
        port = 8888,
        maxclient = 8192,
    })

    skynet.exit()
end)