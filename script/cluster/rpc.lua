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
local function node_reachable(node)
    if node_listen[node] then
        return true
    end
    local last_fail = node_fail_at[node]
    if last_fail and skynet.now() - last_fail < PROXY_RETRY then
        return false
    end
    local spec = node_spec(node)
    if type(spec) ~= "string" then
        return false
    end
    local host, port = spec:match("([^:]+):(%d+)$")
    port = tonumber(port)
    if not host or not port then
        return false
    end
    local socket = require "skynet.socket"
    local ok, fd = pcall(socket.open, host, port)
    if not ok or not fd then
        node_fail_at[node] = skynet.now()
        return false
    end
    socket.close(fd)
    node_listen[node] = true
    node_fail_at[node] = nil
    return true
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

function M.local_addr(name)
    name = ensure_dot(name)
    if not name then
        return nil
    end
    return skynet.localname(name)
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
        if not node_reachable(node) then
            return nil
        end
    end
    return get_proxy(node, name)
end

function M.shard_addr(map_id, shard_id)
    local shard = require "map.shard"
    return M.named(shard.service_name(map_id, shard_id), layout.shard_node(map_id, shard_id))
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
    return M.named(name, layout.named_node(name))
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

-- split：后台连其他 map 上的分片，连上后再让本机片补 ghost
function M.prefetch_remote_shards()
    if not layout.split() then
        return
    end
    skynet.fork(function()
        local shard = require "map.shard"
        local map_id = shard.default_def().map_id
        skynet.sleep(100)
        while true do
            local missing = 0
            for _, sid in ipairs(shard.all_ids()) do
                local node = layout.shard_node(map_id, sid)
                if not layout.is_local(node) then
                    local name = shard.service_name(map_id, sid)
                    if not M.has_proxy(name, node) then
                        missing = missing + 1
                        if node_reachable(node) then
                            M.try_proxy(name, node)
                        end
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

return M
