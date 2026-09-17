-- 跨服务地址：返回值可直接 skynet.call/send。
-- standalone: localname
-- loopback: 本机有服务则 cluster.proxy 打到自己（验证 pack/时序）
-- split: 本机 localname，跨节点 proxy
local skynet = require "skynet"
local log = require "log"
local layout = require "cluster.layout"

local M = {}
local proxies = {}

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
    local cluster = require "skynet.cluster"
    p = cluster.proxy(node, "@" .. cluster_name(name))
    proxies[key] = p
    return p
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
    local local_addr = nil
    if layout.is_local(node) then
        local_addr = M.local_addr(name)
        if not local_addr then
            return nil
        end
    end
    if not layout.use_cluster() then
        log.error("cluster rpc: remote node not enabled, name=%s node=%s", name, tostring(node))
        return local_addr
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
    local cluster = require "skynet.cluster"
    pcall(cluster.unregister, cname)
    cluster.register(cname, addr)
    log.info("cluster export [%s] node=%s", cname, layout.self_node())
    return true
end

return M
