local skynet = require "skynet"
local log = require "log"
local rate_limiter = require "chat.rate_limiter"
local service_ctx = require "runtime.service_ctx"
local channel_mgr = require "chat.channel_mgr"
local WorldChannel = require "chat.world_channel"
local GuildChannel = require "chat.guild_channel"
local event_def = require "define.event_def"

local M = service_ctx.get("chat", {})
M._inited = M._inited or false

local function get_limiters()
    if not M.limiters then
        M.limiters = rate_limiter.create_limiters()
    end
    return M.limiters
end

function M.init()
    if M._inited then
        return true
    end
    M._inited = true

    get_limiters()
    channel_mgr.init()

    local world_channel_id = channel_mgr.create_channel(WorldChannel, 1, "世界频道", channel_mgr.CHANNEL_TYPE.PUBLIC)
    channel_mgr.cache:get(world_channel_id)

    local event = skynet.localname(".event")
    if event then
        skynet.send(event, "lua", "subscribe", event_def.PLAYER.LOGIN, skynet.self())
        skynet.send(event, "lua", "subscribe", event_def.PLAYER.LOGOUT, skynet.self())
        skynet.send(event, "lua", "subscribe", event_def.GUILD.CREATE, skynet.self())
        skynet.send(event, "lua", "subscribe", event_def.GUILD.DISMISS, skynet.self())
    end
    return true
end

function M.on_event(event_name, event_data)
    if event_name == event_def.PLAYER.LOGIN then
        local player_id = event_data.player_id
        local player_name = event_data.player_name
        channel_mgr.join_channel(1, player_id, player_name)
        channel_mgr.on_player_login(player_id)
    elseif event_name == event_def.PLAYER.LOGOUT then
        local player_id = event_data.player_id
        channel_mgr.on_player_logout(player_id)
    elseif event_name == event_def.GUILD.CREATE then
        local guild_id = event_data.guild_id
        local guild_name = event_data.guild_name
        local channel_id = channel_mgr.create_channel(GuildChannel, guild_name .. "公会频道", "guild", guild_id)
        log.info("Guild channel created for guild %d with ID: %d", guild_id, channel_id)
    elseif event_name == event_def.GUILD.DISMISS then
        local guild_id = event_data.guild_id
        for channel_id, channel in pairs(channel_mgr.channels) do
            if channel.channel_type == "guild" and channel:get_guild_id() == guild_id then
                channel_mgr.delete_channel(channel_id)
                log.info("Guild channel deleted for guild %d", guild_id)
                break
            end
        end
    end
end

function M.get_channel_list(player_id)
    return channel_mgr.get_player_channels(player_id)
end

function M.get_channel_members(channel_id)
    local channel = channel_mgr.get_channel(channel_id)
    if not channel then
        return nil, "Channel not found"
    end
    return channel:get_members()
end

function M.send_channel_message(channel_id, player_id, content)
    local limiters = get_limiters()
    if not limiters.global.channel:try_acquire() then
        return false, "Global rate limit exceeded for channel messages"
    end
    return channel_mgr.send_channel_message(channel_id, player_id, content)
end

function M.create_private_channel(player_id, to_player_id)
    return channel_mgr.create_private_channel(player_id, to_player_id)
end

function M.send_private_message(player_id, to_player_id, content)
    local limiters = get_limiters()
    if not limiters.global.private:try_acquire() then
        return false, "Global rate limit exceeded for private messages"
    end
    return channel_mgr.send_private_channel_message(player_id, to_player_id, content)
end

function M.get_channel_history(channel_id, count, player_id)
    local limiters = get_limiters()
    if not limiters.global.history:try_acquire() then
        return nil, "Global rate limit exceeded for history queries"
    end
    return channel_mgr.get_channel_history(channel_id, count)
end

function M.get_private_history(player_id, other_player_id)
    local limiters = get_limiters()
    if not limiters.global.history:try_acquire() then
        return nil, "Global rate limit exceeded for history queries"
    end
    for channel_id, channel in pairs(channel_mgr.channels) do
        if channel.channel_type == "private" then
            local other_id = channel:get_other_player_id(player_id)
            if other_id == other_player_id then
                if channel:is_deleted(player_id) then
                    return {}
                end
                return channel_mgr.get_channel_history(channel_id)
            end
        end
    end
    return nil, "Private channel not found"
end

return M
