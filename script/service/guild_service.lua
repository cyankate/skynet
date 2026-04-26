local skynet = require "skynet"
local service_ctx = require "runtime.service_ctx"
local guild_mgr = require "guild.guild_mgr"
local protocol_handler = require "protocol_handler"

local M = service_ctx.get("guild.guild_service", {})

function M.init()
    if M._inited then
        return
    end
    M._inited = true
    guild_mgr.init()
end

function M.create_guild(player_id, leader_name, guild_name)
    local code, guild_id = guild_mgr.create_guild(player_id, leader_name, guild_name)
    if code ~= guild_mgr.ERROR_CODE.SUCCESS then
        return code
    end
    protocol_handler.send_to_player(player_id, "guild_notification", {
        type = "created",
        guild_id = guild_id,
        guild_name = guild_name,
        message = "恭喜，公会创建成功！",
    })
    return code, guild_id
end

function M.disband_guild(guild_id, player_id)
    return guild_mgr.disband_guild(guild_id, player_id)
end

function M.join_guild(guild_id, player_id, player_name)
    local code = guild_mgr.join_guild(guild_id, player_id, player_name)
    if code ~= guild_mgr.ERROR_CODE.SUCCESS then
        return code
    end
    protocol_handler.send_to_player(player_id, "guild_notification", {
        type = "joined",
        guild_id = guild_id,
        message = "成功加入公会！",
    })
    return code
end

function M.quit_guild(player_id)
    local code = guild_mgr.quit_guild(player_id)
    if code ~= guild_mgr.ERROR_CODE.SUCCESS then
        return code
    end
    skynet.send(".agent", "lua", "notify_guild_quitted", player_id)
    return code
end

function M.kick_member(guild_id, operator_id, target_id)
    local code = guild_mgr.kick_member(guild_id, operator_id, target_id)
    if code ~= guild_mgr.ERROR_CODE.SUCCESS then
        return code
    end
    skynet.send(".agent", "lua", "notify_guild_kicked", target_id, guild_id)
    return code
end

function M.appoint_position(guild_id, operator_id, target_id, new_position)
    local code = guild_mgr.appoint_position(guild_id, operator_id, target_id, new_position)
    if code ~= guild_mgr.ERROR_CODE.SUCCESS then
        return code
    end
    skynet.send(".agent", "lua", "notify_position_changed", target_id, guild_id, new_position)
    return code
end

function M.handle_application(guild_id, operator_id, target_id, accept)
    local code = guild_mgr.handle_application(guild_id, operator_id, target_id, accept)
    if code ~= guild_mgr.ERROR_CODE.SUCCESS then
        return code
    end
    skynet.send(".agent", "lua", "notify_application_handled", target_id, guild_id, accept)
    return code
end

function M.get_guild_info(guild_id)
    return guild_mgr.get_guild_info(guild_id)
end

function M.get_player_guild_info(player_id)
    return guild_mgr.get_player_guild_info(player_id)
end

function M.get_guild_list(page, page_size)
    return guild_mgr.get_guild_list(page, page_size)
end

function M.get_player_guild_point(player_id)
    return guild_mgr.get_player_guild_point(player_id)
end

function M.add_player_guild_point(player_id, delta)
    return guild_mgr.add_player_guild_point(player_id, delta)
end

return M
