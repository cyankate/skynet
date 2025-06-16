local skynet = require "skynet"
local log = require "log"
local guild_mgr = require "guild.guild_mgr"
require "skynet.manager"
local service_wrapper = require "utils.service_wrapper"
local protocol_handler = require "protocol_handler"

function CMD.create_guild(player_id, leader_name, guild_name)
    local code, guild_id = guild_mgr.create_guild(player_id, leader_name, guild_name)
    if code ~= guild_mgr.ERROR_CODE.SUCCESS then
        return code
    end
    -- 可选：通知玩家
    protocol_handler.send_to_player(player_id, "guild_notification", {
        type = "created",
        guild_id = guild_id,
        guild_name = guild_name,
        message = "恭喜，公会创建成功！"
    })
    return code, guild_id
end

function CMD.disband_guild(guild_id, player_id)
    local code = guild_mgr.disband_guild(guild_id, player_id)
    if code ~= guild_mgr.ERROR_CODE.SUCCESS then
        return code
    end
    -- 可选：通知所有成员（可由guild_mgr返回成员列表后通知）
    return code
end

function CMD.join_guild(guild_id, player_id, player_name)
    local code = guild_mgr.join_guild(guild_id, player_id, player_name)
    if code ~= guild_mgr.ERROR_CODE.SUCCESS then
        return code
    end
    protocol_handler.send_to_player(player_id, "guild_notification", {
        type = "joined",
        guild_id = guild_id,
        message = "成功加入公会！"
    })
    return code
end

function CMD.quit_guild(player_id)
    local code = guild_mgr.quit_guild(player_id)
    if code ~= guild_mgr.ERROR_CODE.SUCCESS then
        return code
    end
    skynet.send(".agent", "lua", "notify_guild_quitted", player_id)
    return code
end

function CMD.kick_member(guild_id, operator_id, target_id)
    local code = guild_mgr.kick_member(guild_id, operator_id, target_id)
    if code ~= guild_mgr.ERROR_CODE.SUCCESS then
        return code
    end
    skynet.send(".agent", "lua", "notify_guild_kicked", target_id, guild_id)
    return code
end

function CMD.appoint_position(guild_id, operator_id, target_id, new_position)
    local code = guild_mgr.appoint_position(guild_id, operator_id, target_id, new_position)
    if code ~= guild_mgr.ERROR_CODE.SUCCESS then
        return code
    end
    skynet.send(".agent", "lua", "notify_position_changed", target_id, guild_id, new_position)
    return code
end

function CMD.handle_application(guild_id, operator_id, target_id, accept)
    local code = guild_mgr.handle_application(guild_id, operator_id, target_id, accept)
    if code ~= guild_mgr.ERROR_CODE.SUCCESS then
        return code
    end
    skynet.send(".agent", "lua", "notify_application_handled", target_id, guild_id, accept)
    return code
end

function CMD.get_guild_info(guild_id)
    return guild_mgr.get_guild_info(guild_id)
end

function CMD.get_player_guild_info(player_id)
    return guild_mgr.get_player_guild_info(player_id)
end

function CMD.get_guild_list(page, page_size)
    return guild_mgr.get_guild_list(page, page_size)
end

local function main()
    -- 可选：服务启动逻辑
    guild_mgr.init()
end

service_wrapper.create_service(main, {
    name = "guild",
})
