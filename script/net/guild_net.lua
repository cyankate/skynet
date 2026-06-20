local skynet = require "skynet"
local log = require "log"

local function on_create_guild(player_id, msg)
    if not msg.name or not msg.notice then
        log.error("Invalid create guild format")
        return false, "Invalid message format"
    end
    local guildS = skynet.localname(".guild")
    if not guildS then
        return false, "Guild service not available"
    end
    skynet.send(guildS, "lua", "create_guild", player_id, msg.name, msg.notice)
    return true
end

local function on_disband_guild(player_id, msg)
    local guildS = skynet.localname(".guild")
    if not guildS then
        return false, "Guild service not available"
    end
    skynet.send(guildS, "lua", "disband_guild", player_id)
    return true
end

local function on_join_guild(player_id, msg)
    if not msg.guild_id then
        log.error("Invalid join guild format")
        return false, "Invalid message format"
    end
    local guildS = skynet.localname(".guild")
    if not guildS then
        return false, "Guild service not available"
    end
    skynet.send(guildS, "lua", "join_guild", player_id, msg.guild_id, msg.message)
    return true
end

local function on_quit_guild(player_id, msg)
    local guildS = skynet.localname(".guild")
    if not guildS then
        return false, "Guild service not available"
    end
    skynet.send(guildS, "lua", "quit_guild", player_id)
    return true
end

local function on_kick_member(player_id, msg)
    if not msg.target_id then
        log.error("Invalid kick member format")
        return false, "Invalid message format"
    end
    local guildS = skynet.localname(".guild")
    if not guildS then
        return false, "Guild service not available"
    end
    skynet.send(guildS, "lua", "kick_member", player_id, msg.target_id)
    return true
end

local function on_appoint_position(player_id, msg)
    if not msg.target_id or not msg.position then
        log.error("Invalid appoint position format")
        return false, "Invalid message format"
    end
    local guildS = skynet.localname(".guild")
    if not guildS then
        return false, "Guild service not available"
    end
    skynet.send(guildS, "lua", "appoint_position", player_id, msg.target_id, msg.position)
    return true
end

local function on_modify_notice(player_id, msg)
    if not msg.notice then
        log.error("Invalid modify notice format")
        return false, "Invalid message format"
    end
    local guildS = skynet.localname(".guild")
    if not guildS then
        return false, "Guild service not available"
    end
    skynet.send(guildS, "lua", "modify_notice", player_id, msg.notice)
    return true
end

local function on_modify_join_setting(player_id, msg)
    if msg.need_approval == nil or not msg.min_level or not msg.min_power then
        log.error("Invalid modify join setting format")
        return false, "Invalid message format"
    end
    local guildS = skynet.localname(".guild")
    if not guildS then
        return false, "Guild service not available"
    end
    skynet.send(guildS, "lua", "modify_join_setting", player_id, msg)
    return
end

local function on_handle_application(player_id, msg)
    if not msg.target_id or msg.accept == nil then
        log.error("Invalid handle application format")
        return false, "Invalid message format"
    end
    local guildS = skynet.localname(".guild")
    if not guildS then
        return false, "Guild service not available"
    end
    skynet.send(guildS, "lua", "handle_application", player_id, msg.target_id, msg.accept)
    return true
end

local function on_get_guild_info(player_id, msg)
    local guildS = skynet.localname(".guild")
    if not guildS then
        return false, "Guild service not available"
    end
    skynet.send(guildS, "lua", "get_guild_info", player_id)
    return true
end

local function on_get_guild_list(player_id, msg)
    local page = msg.page or 1
    local page_size = msg.page_size or 10
    local guildS = skynet.localname(".guild")
    if not guildS then
        return false, "Guild service not available"
    end
    skynet.send(guildS, "lua", "get_guild_list", page, page_size)
    return true
end

local function on_get_application_list(player_id, msg)
    local guildS = skynet.localname(".guild")
    if not guildS then
        return false, "Guild service not available"
    end
    skynet.send(guildS, "lua", "get_application_list", player_id)
    return true
end

return {
    create_guild = on_create_guild,
    disband_guild = on_disband_guild,
    join_guild = on_join_guild,
    quit_guild = on_quit_guild,
    kick_member = on_kick_member,
    appoint_position = on_appoint_position,
    modify_notice = on_modify_notice,
    modify_join_setting = on_modify_join_setting,
    handle_application = on_handle_application,
    get_guild_info = on_get_guild_info,
    get_guild_list = on_get_guild_list,
    get_application_list = on_get_application_list,
}
