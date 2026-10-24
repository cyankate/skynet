local skynet = require "skynet"
local log = require "log"
local shard = require "map.shard"
local layout = require "cluster.layout"
local rpc = require "cluster.rpc"
require "skynet.manager"

local function open_cluster()
    if not layout.use_cluster() then
        return
    end
    local cluster = require "skynet.cluster"
    cluster.open(layout.self_node())
    log.info("cluster opened, node=%s mode=%s role=%s", layout.self_node(), layout.mode(), layout.role())
end

local function launch_local_shards()
    local map_id = shard.default_def().map_id
    local ids = layout.local_shard_ids()
    log.info("launch shards on %s: %s", layout.self_node(), table.concat(ids, ","))
    for _, sid in ipairs(ids) do
        local name = shard.service_name(map_id, sid)
        if not skynet.localname(name) then
            skynet.newservice("shardS", map_id, sid)
        end
        local n = 0
        while not skynet.localname(name) and n < 50 do
            skynet.sleep(10)
            n = n + 1
        end
        if not skynet.localname(name) then
            log.error("map shard not ready, map_id=%s shard_id=%s", tostring(map_id), tostring(sid))
        end
    end
end

skynet.start(function()
    skynet.newservice("hotfixS")
    open_cluster()

    if layout.role() == "map" then
        local port = tonumber(skynet.getenv("debug_port")) or 8891
        skynet.newservice("debug_console", port)
        launch_local_shards()
        rpc.prefetch_remote_shards()
        -- split 下 main 不能 exit，否则 prefetch 协程被杀掉
        return
    end

    skynet.uniqueservice("protoloader")

    skynet.newservice("dbS")
    skynet.newservice("redisS")
    skynet.newservice("mongoS")
    skynet.newservice("debug_console")
    skynet.newservice("eventS")
    skynet.newservice("securityS")
    skynet.newservice("locatorS")
    skynet.newservice("loginS")
    skynet.newservice("rankS")
    skynet.newservice("guildS")
    skynet.newservice("globalS")
    skynet.newservice("chatS")
    skynet.newservice("httpS")
    skynet.newservice("mailS")
    skynet.newservice("friendS")
    skynet.newservice("paymentS")
    if layout.gate_count() > 1 and not layout.behind_lb() then
        log.warning("gate_count>1 需要 nginx + gate_behind_lb=1，否则会和 http 8889 抢端口")
    end
    local gates = {}
    for _, id in ipairs(layout.gate_ids()) do
        gates[#gates + 1] = { id = id, addr = skynet.newservice("gateS", id) }
    end
    skynet.newservice("matchS")
    skynet.newservice("instanceS")
    skynet.newservice("pathfindingS")
    skynet.newservice("mapS", shard.default_def().map_id)
    rpc.prefetch_remote_shards()

    for _, g in ipairs(gates) do
        skynet.call(g.addr, "lua", "open", {
            address = layout.gate_listen_addr(),
            port = layout.gate_port(g.id),
            maxclient = 8192,
        })
        log.info("gate listen, name=%s %s:%s", layout.gate_name(g.id),
            layout.gate_listen_addr(), tostring(layout.gate_port(g.id)))
    end

    if layout.split() then
        return
    end

    skynet.exit()
end)
