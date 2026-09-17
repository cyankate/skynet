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
        return false
    end
    socket.close(fd)
    node_listen[node] = true
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

-- name: ".gate" / ".shard.1001.1"
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
    -- 其他 map 上的分片：热路径不主动连（对端未起时 cluster.proxy init 会 Connection refused 刷屏）
    if not layout.is_local(node) and name:match("^%.shard%.") then
        return proxies[node .. "\0" .. name]
    end
    return get_proxy(node, name)
end

function M.shard_addr(map_id, shard_id)
    local shard = require "map.shard"
    return M.named(shard.service_name(map_id, shard_id), layout.shard_node(map_id, shard_id))
end

-- 本节点 gate：绑定 fd、顶号踢本连接、reload proto。多 gate 之后仍然只打自己，不走 cluster。
function M.local_gate()
    return M.local_addr(".gate")
end

-- 玩家当前所在 gate（下行）。loopback 时走 cluster 环回。
function M.player_gate(player_id)
    return M.named(".gate", layout.gate_node(player_id))
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
            local waiting = {}
            for _, sid in ipairs(shard.all_ids()) do
                local node = layout.shard_node(map_id, sid)
                if not layout.is_local(node) then
                    local name = shard.service_name(map_id, sid)
                    if not M.has_proxy(name, node) then
                        missing = missing + 1
                        if node_reachable(node) then
                            M.try_proxy(name, node)
                        else
                            waiting[node] = true
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
