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
    -- supervisor 必须最先起来：它接管本进程的退出通知
    local ok, sup_or_err = pcall(skynet.newservice, "supervisorS")
    local supervisor
    if ok then
        supervisor = sup_or_err
    else
        log.error("supervisor start failed: %s", tostring(sup_or_err))
    end

    local function watch(handle, spec)
        if supervisor and handle then
            pcall(skynet.call, supervisor, "lua", "watch", handle, spec)
        end
        return handle
    end

    local function spawn(entry, spec)
        local h = skynet.newservice(entry)
        spec = spec or { entry = entry, kind = "named" }
        spec.entry = spec.entry or entry
        return watch(h, spec)
    end

    watch(skynet.newservice("hotfixS"), { entry = "hotfixS", kind = "named" })
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

    -- 基础设施可能卡在长查询里，卡死只告警不自动 kill
    spawn("dbS", { entry = "dbS", kind = "named", kill_on_hang = false })
    spawn("redisS", { entry = "redisS", kind = "named", kill_on_hang = false })
    spawn("mongoS", { entry = "mongoS", kind = "named", kill_on_hang = false })
    skynet.newservice("debug_console")
    -- eventS 的订阅表在内存里，重启后订阅方不会自动重订阅（见后续改造）；先只感知不自动拉起
    spawn("eventS", { entry = "eventS", kind = "named", restart = false })
    spawn("securityS")
    spawn("locatorS")
    spawn("loginS")
    spawn("rankS")
    spawn("guildS")
    spawn("globalS")
    spawn("chatS")
    spawn("httpS")
    spawn("mailS")
    spawn("friendS")
    spawn("paymentS")
    if layout.gate_count() > 1 and not layout.behind_lb() then
        log.warning("gate_count>1 需要 nginx + gate_behind_lb=1，否则会和 http 8889 抢端口")
    end
    local gates = {}
    for _, id in ipairs(layout.gate_ids()) do
        local conf = {
            address = layout.gate_listen_addr(),
            port = layout.gate_port(id),
            maxclient = 8192,
        }
        local h = skynet.newservice("gateS", id)
        watch(h, {
            entry = "gateS",
            args = { id },
            kind = "gate",
            start_call = { method = "open", args = { conf } },
        })
        gates[#gates + 1] = { id = id, addr = h, conf = conf }
    end
    spawn("matchS")
    spawn("instanceS")
    spawn("pathfindingS")
    spawn("tradeS")
    local map_id = shard.default_def().map_id
    watch(skynet.newservice("mapS", map_id), {
        entry = "mapS",
        args = { map_id },
        kind = "map",
    })
    rpc.prefetch_remote_shards()

    for _, g in ipairs(gates) do
        skynet.call(g.addr, "lua", "open", g.conf)
        log.info("gate listen, name=%s %s:%s", layout.gate_name(g.id),
            g.conf.address, tostring(g.conf.port))
    end

    if layout.split() then
        return
    end

    skynet.exit()
end)
