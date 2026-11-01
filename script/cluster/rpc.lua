-- 跨服务地址：返回值可直接 skynet.call/send。
-- standalone: localname
-- loopback: 本机有服务则 cluster.proxy 打到自己（验证 pack/时序）
-- split: 本机 localname，跨节点 proxy
local skynet = require "skynet"
local log = require "log"
local layout = require "cluster.layout"

local M = {}
local proxies = {}
local proxy_fail_at = {}
local node_listen = {}
local node_fail_at = {}
local cluster_nodes
local PROXY_RETRY = 300

-- 运行时注册表缓存（每服务一份 VM）。节点不迁移，缓存主要挡重复查询。
local registry_nodes = {}
local registry_miss = {}
local shard_nodes = {}
local shard_miss = {}
local REG_TTL = 1000
local REG_RETRY = 100

local function clusterd()
    return skynet.uniqueservice("clusterd")
end

local function node_spec(node)
    if not cluster_nodes then
        cluster_nodes = {}
        local path = skynet.getenv("cluster")
        if path then
            local env = {}
            local chunk = loadfile(path, "t", env)
            if chunk then
                chunk()
                cluster_nodes = env
            end
        end
    end
    return cluster_nodes[node]
end

-- 只判断端口有没有人听，失败不会走 cluster.proxy（避免 clusterd assert 刷屏）
-- 第二个返回值表示本次是否真的探测了（false = 命中缓存/节流，不代表状态变化）
local function node_reachable(node)
    if node_listen[node] then
        return true, false
    end
    local last_fail = node_fail_at[node]
    if last_fail and skynet.now() - last_fail < PROXY_RETRY then
        return false, false
    end
    local spec = node_spec(node)
    if type(spec) ~= "string" then
        return false, false
    end
    local host, port = spec:match("([^:]+):(%d+)$")
    port = tonumber(port)
    if not host or not port then
        return false, false
    end
    local socket = require "skynet.socket"
    local ok, fd = pcall(socket.open, host, port)
    if not ok or not fd then
        node_fail_at[node] = skynet.now()
        return false, true
    end
    socket.close(fd)
    node_listen[node] = true
    node_fail_at[node] = nil
    return true, false
end

local function ensure_dot(name)
    if type(name) ~= "string" or name == "" then
        return nil
    end
    if name:sub(1, 1) ~= "." then
        return "." .. name
    end
    return name
end

local function cluster_name(name)
    name = ensure_dot(name)
    if not name then
        return nil
    end
    return name:sub(2)
end

-- 注册表的根是 locator，永远按静态布局解析，避免自调用。
local function locator_addr()
    return M.named(".locator", layout.named_node(".locator"))
end

-- 静态表只做兜底：服务启动后会向 locator 登记，节点位置以注册表为准。
function M.node_of(name)
    name = ensure_dot(name)
    if not name then
        return layout.self_node()
    end
    if name ~= ".locator" and layout.use_cluster() then
        local c = registry_nodes[name]
        if c and skynet.now() - c.ts < REG_TTL then
            return c.node
        end
        local miss = registry_miss[name]
        if not (miss and skynet.now() - miss < REG_RETRY) then
            local loc = locator_addr()
            if loc then
                local ok, node = pcall(skynet.call, loc, "lua", "lookup_service", cluster_name(name))
                if ok and type(node) == "string" and node ~= "" then
                    registry_nodes[name] = { node = node, ts = skynet.now() }
                    registry_miss[name] = nil
                    return node
                end
            end
            registry_miss[name] = skynet.now()
        end
    end
    return layout.named_node(name)
end

function M.shard_node(map_id, shard_id)
    map_id = tonumber(map_id) or 0
    shard_id = tonumber(shard_id) or 0
    local key = tostring(map_id) .. ":" .. tostring(shard_id)
    if layout.use_cluster() then
        local c = shard_nodes[key]
        if c and skynet.now() - c.ts < REG_TTL then
            return c.node
        end
        local miss = shard_miss[key]
        if not (miss and skynet.now() - miss < REG_RETRY) then
            local loc = locator_addr()
            if loc then
                local ok, info = pcall(skynet.call, loc, "lua", "lookup_shard", map_id, shard_id)
                if ok and type(info) == "table" and type(info.node) == "string" and info.node ~= "" then
                    shard_nodes[key] = { node = info.node, ts = skynet.now() }
                    shard_miss[key] = nil
                    return info.node
                end
            end
            shard_miss[key] = skynet.now()
        end
    end
    return layout.shard_node(map_id, shard_id)
end

-- 登记后转心跳：locator 重启丢表时，服务会在一个周期内自动补登。
-- 被别的节点占着时 register 返回 conflict，直到旧租约过期才允许接管。
local HEARTBEAT = 3000 -- 30s
local function register_retry(desc, fn, on_reject)
    skynet.fork(function()
        local tries = 0
        while true do
            local loc = locator_addr()
            if loc then
                local ok, result, reason = pcall(skynet.call, loc, "lua", fn[1], table.unpack(fn, 2))
                if ok and result then
                    tries = 0
                    skynet.sleep(HEARTBEAT)
                elseif ok then
                    log.error("cluster register rejected, %s (%s)", desc, tostring(reason))
                    if on_reject then
                        on_reject()
                    end
                    skynet.sleep(HEARTBEAT)
                else
                    skynet.sleep(100)
                end
            else
                tries = tries + 1
                if tries % 30 == 0 then
                    log.warning("cluster registry unavailable, %s (retry %d)", desc, tries)
                end
                skynet.sleep(100)
            end
        end
    end)
end

-- 服务启动时调用：向 locator 登记自己所在的节点。
function M.register(name, node)
    if not layout.use_cluster() then
        return false
    end
    name = ensure_dot(name)
    local cname = cluster_name(name)
    if not cname or cname == "locator" then
        return false
    end
    node = node or layout.self_node()
    registry_nodes[name] = { node = node, ts = skynet.now() }
    registry_miss[name] = nil
    register_retry("service " .. cname .. " node " .. node, { "register_service", cname, node }, function()
        registry_nodes[name] = nil
    end)
    return true
end

function M.unregister(name, node)
    if not layout.use_cluster() then
        return false
    end
    name = ensure_dot(name)
    local cname = cluster_name(name)
    if not cname then
        return false
    end
    registry_nodes[name] = nil
    local loc = locator_addr()
    if not loc then
        return false
    end
    local ok = pcall(skynet.call, loc, "lua", "unregister_service", cname, node or layout.self_node())
    return ok
end

-- 分片启动时调用：登记 (map_id, shard_id) 落在哪个节点。
function M.register_shard(map_id, shard_id, service_name, node)
    if not layout.use_cluster() then
        return false
    end
    node = node or layout.self_node()
    local key = tostring(tonumber(map_id) or map_id) .. ":" .. tostring(tonumber(shard_id) or shard_id)
    shard_nodes[key] = { node = node, ts = skynet.now() }
    shard_miss[key] = nil
    register_retry(
        "shard " .. key .. " node " .. node,
        { "register_shard", map_id, shard_id, node, service_name },
        function()
            shard_nodes[key] = nil
        end
    )
    return true
end

-- 热更新节点地址：clusterd 会按新地址重连；这里清掉本 VM 的地址/探活缓存。
function M.reload_cluster(config)
    if not layout.use_cluster() then
        return false
    end
    local ok, err = pcall(require("skynet.cluster").reload, config)
    if not ok then
        log.error("cluster reload failed: %s", tostring(err))
        return false
    end
    cluster_nodes = nil
    node_listen = {}
    node_fail_at = {}
    log.info("cluster reloaded, node caches cleared")
    return true
end

function M.local_addr(name)
    name = ensure_dot(name)
    if not name then
        return nil
    end
    return skynet.localname(name)
end

-- 建 proxy 失败：立刻丢掉注册表缓存，下一次重新问 locator。
-- TTL 仍保留，负责 send 静默失败这类感知不到的场景。
local function forget_registry(name)
    registry_nodes[name] = nil
    registry_miss[name] = nil
    local map_id, sid = name:match("^%.shard%.(%d+)%.(%d+)$")
    if not map_id then
        map_id, sid = name:match("^%.scene%.map%.(%d+)%.(%d+)$")
    end
    if map_id then
        local key = map_id .. ":" .. sid
        shard_nodes[key] = nil
        shard_miss[key] = nil
    end
end

local function get_proxy(node, name)
    name = ensure_dot(name)
    if not name or not node then
        return nil
    end
    local key = node .. "\0" .. name
    local p = proxies[key]
    if p then
        return p
    end
    local last_fail = proxy_fail_at[key]
    if last_fail and skynet.now() - last_fail < PROXY_RETRY then
        return nil
    end
    -- 对端进程未起时 cluster.proxy 会在 init 里连 TCP 失败；不能让业务 init 跟着死。
    local ok, result = pcall(skynet.call, clusterd(), "lua", "proxy", node, "@" .. cluster_name(name))
    if not ok or not result then
        proxy_fail_at[key] = skynet.now()
        forget_registry(name)
        return nil
    end
    proxy_fail_at[key] = nil
    proxies[key] = result
    return result
end

function M.has_proxy(name, node)
    name = ensure_dot(name)
    node = node or layout.self_node()
    if not name then
        return false
    end
    return proxies[node .. "\0" .. name] ~= nil
end

function M.try_proxy(name, node)
    return get_proxy(node, name)
end

-- name: ".gate.1" / ".shard.1001.1"
function M.named(name, node)
    name = ensure_dot(name)
    if not name then
        return nil
    end
    node = node or layout.self_node()
    if layout.is_local(node) and not layout.loopback() then
        return M.local_addr(name)
    end
    if layout.is_local(node) then
        if not M.local_addr(name) then
            return nil
        end
    end
    if not layout.use_cluster() then
        log.error("cluster rpc: remote node not enabled, name=%s node=%s", name, tostring(node))
        return M.local_addr(name)
    end
    -- 每个服务一份 VM，main 的 prefetch 填不满其它服务的 proxies。
    -- 跨节点：有缓存直接用；没有则先探端口再建 proxy（对端未起不走 cluster.proxy）。
    if not layout.is_local(node) then
        local cached = proxies[node .. "\0" .. name]
        if cached then
            return cached
        end
        local reachable, probed = node_reachable(node)
        if not reachable then
            -- 端口探测失败：注册表里这个答案已经不可用，下次立刻重查
            if probed then
                forget_registry(name)
            end
            return nil
        end
    end
    return get_proxy(node, name)
end

function M.shard_addr(map_id, shard_id)
    local shard = require "map.shard"
    return M.named(shard.service_name(map_id, shard_id), M.shard_node(map_id, shard_id))
end

local player_gates = {} -- 本 VM：player_id => { name, node }

function M.forget_player_gate(player_id)
    player_id = tonumber(player_id)
    if player_id then
        player_gates[player_id] = nil
    end
end

local function fetch_gates(player_ids)
    local a = M.named_addr(".locator")
    if not a then
        return {}
    end
    local ok, sesses = pcall(skynet.call, a, "lua", "get_gates", player_ids)
    if not ok or type(sesses) ~= "table" then
        return {}
    end
    return sesses
end

local function store_gate(pid, sess)
    if type(sess) ~= "table" or not sess.name then
        return nil
    end
    player_gates[pid] = { name = sess.name, node = sess.node }
    return M.named(sess.name, sess.node)
end

function M.all_gates()
    local t = {}
    local seen = {}
    for _, id in ipairs(layout.gate_ids()) do
        local a = M.named(layout.gate_name(id), layout.gate_home_node())
        if a and not seen[a] then
            seen[a] = true
            t[#t + 1] = a
        end
    end
    return t
end

-- 玩家当前所在 gate。本 VM 缓存，miss 才问 locator；换门由 locator 通知分片 forget。仅分片直推连接用。
function M.player_gate(player_id)
    local pid = tonumber(player_id)
    if not pid then
        return nil
    end
    local c = player_gates[pid]
    if c then
        return M.named(c.name, c.node)
    end
    return store_gate(pid, fetch_gates({ pid })[pid])
end

-- 群发：缓存命中的直接用，剩下一次 get_gates。回填本 VM 缓存，后续 send_to_conn 也能打中。
function M.player_gates(player_ids)
    if type(player_ids) ~= "table" then
        return {}
    end
    local result = {}
    local missing = {}
    for _, player_id in ipairs(player_ids) do
        local pid = tonumber(player_id)
        if pid then
            local c = player_gates[pid]
            if c then
                local gate = M.named(c.name, c.node)
                if gate then
                    result[pid] = gate
                end
            else
                missing[#missing + 1] = pid
            end
        end
    end
    if #missing == 0 then
        return result
    end
    local sesses = fetch_gates(missing)
    for _, pid in ipairs(missing) do
        local gate = store_gate(pid, sesses[pid])
        if gate then
            result[pid] = gate
        end
    end
    return result
end

function M.named_addr(name)
    name = ensure_dot(name)
    return M.named(name, M.node_of(name))
end

-- 把本服务登记到 clusterd，对端用 @name 访问。name 可带或不带点。
function M.export(name, addr)
    if not layout.use_cluster() then
        return false
    end
    local cname = cluster_name(name)
    if not cname then
        return false
    end
    addr = addr or skynet.self()
    local c = clusterd()
    pcall(skynet.call, c, "lua", "unregister", cname)
    skynet.call(c, "lua", "register", cname, addr)
    log.info("cluster export [%s] node=%s", cname, layout.self_node())
    return true
end

-- split：后台连其他 map 上的分片，连上后再让本机片补 ghost。
-- 期望的远程片 = 静态布局 ∪ locator 注册表（注册表优先，支持分片换节点）。
function M.prefetch_remote_shards()
    if not layout.split() then
        return
    end
    skynet.fork(function()
        local shard = require "map.shard"
        local map_id = shard.default_def().map_id
        skynet.sleep(100)
        while true do
            local want = {}
            local function set(name, node)
                if not name then
                    return
                end
                if node and node ~= "" and not layout.is_local(node) then
                    want[name] = node
                else
                    want[name] = nil
                end
            end
            -- 静态兜底：远程片还没登记时也要等它
            for _, sid in ipairs(shard.all_ids()) do
                set(shard.service_name(map_id, sid), layout.shard_node(map_id, sid))
            end
            -- 注册表覆盖静态（包括动态增加/迁移/迁回本机的片）
            local loc = locator_addr()
            if loc then
                local ok, list = pcall(skynet.call, loc, "lua", "list_shards", map_id)
                if ok and type(list) == "table" then
                    for _, info in ipairs(list) do
                        set(info.name or shard.service_name(map_id, info.shard_id), info.node)
                    end
                end
            end
            local missing = 0
            for name, node in pairs(want) do
                if not M.has_proxy(name, node) then
                    missing = missing + 1
                    if node_reachable(node) then
                        M.try_proxy(name, node)
                    end
                end
            end
            if missing == 0 then
                log.info("cluster remote shards ready, node=%s", layout.self_node())
                for _, sid in ipairs(layout.local_shard_ids()) do
                    local addr = skynet.localname(shard.service_name(map_id, sid))
                    if addr then
                        skynet.send(addr, "lua", "resync_border_ghosts")
                    end
                end
                return
            end
            skynet.sleep(200)
        end
    end)
end

-- 带超时的 call：对端卡死时不会把调用方一起拖死。
-- timeout 单位是 0.01 秒；超时后远端仍可能继续处理，重试需要幂等。
-- 返回：completed（调用是否完成）、ret1/ret2（远端返回值），失败时 err。
function M.call_timeout(addr, timeout, method, ...)
    if not addr then
        return false, nil, "no address"
    end
    local args = table.pack(...)
    local token = {}
    local done = false
    local completed, ret1, ret2 = false, nil, nil
    skynet.fork(function()
        local ok, r1, r2 = pcall(skynet.call, addr, "lua", method, table.unpack(args, 1, args.n))
        completed = ok
        if ok then
            ret1, ret2 = r1, r2
        else
            ret2 = r1
        end
        done = true
        skynet.wakeup(token)
    end)
    skynet.sleep(timeout, token)
    if not done then
        return false, nil, "timeout"
    end
    if not completed then
        return false, nil, ret2
    end
    return true, ret1, ret2
end

return M
