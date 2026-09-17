-- 节点放置：谁在哪台机器。
-- cluster_mode:
--   standalone  本机 localname，不走 TCP（低在线 / 开发默认可改回这个）
--   loopback    本机服务仍在、但 rpc.named 走 cluster.proxy 环回（第 2 步验证打包）
--   split       跨节点 cluster（第 3 步）
local skynet = require "skynet"

local M = {}

M.STANDALONE = "standalone"

-- shard_id -> 节点名；空则本节点（第 3 步往这里填 map1/map2）
local SHARD_NODE = {
    -- [1] = "map1",
}

-- 具名服务 -> 节点名（.login / .register / .map.<id> …）；空则本节点
local NAMED_NODE = {
    -- [".login"] = "world",
}

function M.self_node()
    return skynet.getenv("node_name") or M.STANDALONE
end

function M.mode()
    return skynet.getenv("cluster_mode") or "standalone"
end

function M.use_cluster()
    local mode = M.mode()
    return mode == "loopback" or mode == "split"
end

function M.loopback()
    return M.mode() == "loopback"
end

function M.is_local(node)
    if not node or node == "" then
        return true
    end
    return node == M.self_node()
end

function M.shard_node(_map_id, shard_id)
    local sid = tonumber(shard_id)
    if sid and SHARD_NODE[sid] then
        return SHARD_NODE[sid]
    end
    return M.self_node()
end

-- 下行按玩家找 gate；第 4 步才变成会话表。fd 相关操作必须用 local_gate，不能走这个。
function M.gate_node(_player_id)
    return M.self_node()
end

function M.named_node(name)
    if type(name) == "string" and NAMED_NODE[name] then
        return NAMED_NODE[name]
    end
    return M.self_node()
end

return M
