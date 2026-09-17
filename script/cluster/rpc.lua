-- 跨服务地址：返回值可直接 skynet.call/send。
-- 第 1 步只解析本机 localname；跨节点在 layout.is_local == false 时再接 cluster.proxy。
local skynet = require "skynet"
local log = require "log"
local layout = require "cluster.layout"

local M = {}

local function ensure_dot(name)
    if type(name) ~= "string" or name == "" then
        return nil
    end
    if name:sub(1, 1) ~= "." then
        return "." .. name
    end
    return name
end

function M.local_addr(name)
    name = ensure_dot(name)
    if not name then
        return nil
    end
    return skynet.localname(name)
end

-- name: ".gate" / ".shard.1001.1"
-- node: layout 里的节点名，本节点或 nil 则 localname
function M.named(name, node)
    name = ensure_dot(name)
    if not name then
        return nil
    end
    if not layout.is_local(node) then
        log.error("cluster rpc: remote node not enabled, name=%s node=%s", name, tostring(node))
        return nil
    end
    return M.local_addr(name)
end

function M.shard_addr(map_id, shard_id)
    local shard = require "map.shard"
    return M.named(shard.service_name(map_id, shard_id), layout.shard_node(map_id, shard_id))
end

-- 本节点 gate：绑定 fd、顶号踢本连接、reload proto。多 gate 之后仍然只打自己。
function M.local_gate()
    return M.local_addr(".gate")
end

-- 玩家当前所在 gate（下行）。standalone 与 local_gate 相同。
function M.player_gate(player_id)
    return M.named(".gate", layout.gate_node(player_id))
end

function M.named_addr(name)
    return M.named(name, layout.named_node(ensure_dot(name)))
end

return M
