-- 在线目录客户端：各服务不要直接 localname(".locator")
local skynet = require "skynet"
local rpc = require "cluster.rpc"

local M = {}

local function addr()
    return rpc.named_addr(".locator")
end

function M.bind(player_id, gate_name, node)
    local a = addr()
    if not a then
        return false, "locator service not available"
    end
    return skynet.call(a, "lua", "bind", player_id, gate_name, node)
end

function M.unbind(player_id, gate_name, node)
    local a = addr()
    if not a then
        return false
    end
    return skynet.call(a, "lua", "unbind", player_id, gate_name, node)
end

function M.kick(player_id, reason, message)
    local a = addr()
    if not a then
        return false
    end
    local ok, result = pcall(skynet.call, a, "lua", "kick", player_id, reason, message)
    if not ok then
        return false
    end
    return result
end

function M.set_agent(player_id, agent)
    local a = addr()
    if not a then
        return false
    end
    return skynet.call(a, "lua", "set_agent", player_id, agent)
end

function M.get_agent(player_id)
    local a = addr()
    if not a then
        return nil
    end
    local ok, agent = pcall(skynet.call, a, "lua", "get_agent", player_id)
    if not ok then
        return nil
    end
    return agent
end

function M.get_agents(player_ids)
    local a = addr()
    if not a then
        return {}
    end
    local ok, result = pcall(skynet.call, a, "lua", "get_agents", player_ids)
    if not ok or type(result) ~= "table" then
        return {}
    end
    return result
end

function M.remove(player_id)
    local a = addr()
    if not a then
        return false
    end
    return skynet.call(a, "lua", "remove", player_id)
end

-- 玩家所在分片：切片时由 agent 回报；门直连与跨片兜底查询用。
-- 位置是尽力而为的提示，失败不能影响业务主流程。
function M.set_scene(player_id, map_id, shard_id, scene_id)
    local a = addr()
    if not a then
        return false
    end
    local ok, result = pcall(skynet.call, a, "lua", "set_scene", player_id, map_id, shard_id, scene_id)
    if not ok then
        return false
    end
    return result
end

function M.clear_scene(player_id)
    local a = addr()
    if not a then
        return false
    end
    local ok, result = pcall(skynet.call, a, "lua", "clear_scene", player_id)
    if not ok then
        return false
    end
    return result
end

function M.get_scene(player_id)
    local a = addr()
    if not a then
        return nil
    end
    local ok, scene = pcall(skynet.call, a, "lua", "get_scene", player_id)
    if not ok then
        return nil
    end
    return scene
end

function M.get_scenes(player_ids)
    local a = addr()
    if not a then
        return {}
    end
    local ok, result = pcall(skynet.call, a, "lua", "get_scenes", player_ids)
    if not ok or type(result) ~= "table" then
        return {}
    end
    return result
end

return M
