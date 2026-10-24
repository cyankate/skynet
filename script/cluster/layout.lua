-- 节点放置：谁在哪台机器。
-- cluster_mode:
--   standalone  本机 localname，不走 TCP
--   loopback    仍一个进程，rpc.named 走 cluster.proxy 环回
--   split       game + map1 + map2 多进程
local skynet = require "skynet"

local M = {}

M.GAME = "game"

-- split 时：1、2 同行在 map1，3、4 同行在 map2（贴边尽量同进程）
local SHARD_NODE = {
    [1] = "map1",
    [2] = "map1",
    [3] = "map2",
    [4] = "map2",
}

local NAMED_NODE = {
    [".locator"] = M.GAME,
    [".pathfinding"] = M.GAME,
    [".mongo"] = M.GAME,
    [".login"] = M.GAME,
    [".instance"] = M.GAME,
}

function M.self_node()
    return skynet.getenv("node_name") or "standalone"
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
    if n == M.GAME then
        return "game"
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
    return M.GAME
end

-- 所有 gate 目前都在 game/本进程；按 player_id 找具体 gate 走 locator
function M.gate_home_node()
    if M.split() then
        return M.GAME
    end
    return M.self_node()
end

function M.gate_count()
    local n = tonumber(skynet.getenv("gate_count")) or 1
    if n < 1 then
        n = 1
    end
    return n
end

function M.gate_ids()
    local t = {}
    for i = 1, M.gate_count() do
        t[#t + 1] = i
    end
    return t
end

function M.gate_name(id)
    return ".gate." .. tostring(id)
end

-- 前面挂 nginx 时：门只听本机 19001/19002，公网 8000 由 nginx 转。开发不配这项，直接连 8888。
function M.behind_lb()
    local v = skynet.getenv("gate_behind_lb")
    return v == "1" or v == "true"
end

function M.gate_listen_addr()
    if M.behind_lb() then
        return "127.0.0.1"
    end
    return "0.0.0.0"
end

function M.gate_port(id)
    id = tonumber(id) or 1
    if M.behind_lb() then
        return (tonumber(skynet.getenv("gate_internal_port")) or 19000) + id
    end
    local base = tonumber(skynet.getenv("gate_port")) or 8888
    return base + (id - 1)
end

function M.named_node(name)
    if not M.split() then
        return M.self_node()
    end
    if type(name) == "string" and name:match("^%.gate%.") then
        return M.GAME
    end
    if type(name) == "string" and NAMED_NODE[name] then
        return NAMED_NODE[name]
    end
    if type(name) == "string" and name:match("^%.map%.") then
        return M.GAME
    end
    return M.GAME
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
