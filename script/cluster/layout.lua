-- 节点放置：谁在哪台机器。
-- cluster_mode:
--   standalone  本机 localname，不走 TCP
--   loopback    仍一个进程，rpc.named 走 cluster.proxy 环回
--   split       world + map1 + map2 多进程
local skynet = require "skynet"

local M = {}

M.STANDALONE = "standalone"
M.WORLD = "world"

-- split 时：1、2 同行在 map1，3、4 同行在 map2（贴边尽量同进程）
local SHARD_NODE = {
    [1] = "map1",
    [2] = "map1",
    [3] = "map2",
    [4] = "map2",
}

local NAMED_NODE = {
    [".gate"] = "world",
    [".register"] = "world",
    [".pathfinding"] = "world",
    [".mongo"] = "world",
    [".login"] = "world",
    [".instance"] = "world",
}

function M.self_node()
    return skynet.getenv("node_name") or M.STANDALONE
end

function M.mode()
    return skynet.getenv("cluster_mode") or "standalone"
end

function M.role()
    local r = skynet.getenv("node_role")
    if r and r ~= "" then
        return r
    end
    local n = M.self_node()
    if n == "map1" or n == "map2" then
        return "map"
    end
    if n == M.WORLD then
        return "world"
    end
    return "all"
end

function M.use_cluster()
    local mode = M.mode()
    return mode == "loopback" or mode == "split"
end

function M.loopback()
    return M.mode() == "loopback"
end

function M.split()
    return M.mode() == "split"
end

function M.is_local(node)
    if not node or node == "" then
        return true
    end
    return node == M.self_node()
end

function M.shard_node(_map_id, shard_id)
    if not M.split() then
        return M.self_node()
    end
    local sid = tonumber(shard_id)
    if sid and SHARD_NODE[sid] then
        return SHARD_NODE[sid]
    end
    return M.WORLD
end

function M.gate_node(_player_id)
    if M.split() then
        return M.WORLD
    end
    return M.self_node()
end

function M.named_node(name)
    if not M.split() then
        return M.self_node()
    end
    if type(name) == "string" and NAMED_NODE[name] then
        return NAMED_NODE[name]
    end
    if type(name) == "string" and name:match("^%.map%.") then
        return M.WORLD
    end
    return M.WORLD
end

function M.local_shard_ids()
    local shard = require "map.shard"
    local ids = {}
    for _, sid in ipairs(shard.all_ids()) do
        if M.is_local(M.shard_node(nil, sid)) then
            ids[#ids + 1] = sid
        end
    end
    return ids
end

return M
