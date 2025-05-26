local skynet = require "skynet"
local log = require "log"
require "skynet.manager"
local service_wrapper = require "utils.service_wrapper"
local protocol_handler = require "protocol_handler"
local rate_limiter = require "chat.rate_limiter"

-- 导入频道相关模块
local channel_mgr = require "chat.channel_mgr"
local world_channel = require "chat.world_channel"
local guild_channel = require "chat.guild_channel"
local private_channel = require "chat.private_channel"

local limiters = nil

-- 初始化服务
function CMD.init()
    -- 初始化限流器
    limiters = rate_limiter.create_limiters()
    
    -- 初始化频道管理器
    channel_mgr.init()
    
    -- 创建世界频道
    local world_channel_id = channel_mgr.create_channel(world_channel, 1, "世界频道", CHANNEL_TYPE.PUBLIC)
    channel_mgr.cache:get(world_channel_id)

    -- -- 创建系统频道
    -- local system_channel_id = channel_mgr.create_channel(system_channel, 2, "系统频道", CHANNEL_TYPE.PUBLIC)
    -- channel_mgr.cache:get(system_channel_id)
    
    -- 注册事件处理
    local event = skynet.localname(".event")
    skynet.send(event, "lua", "subscribe", "player.login", skynet.self())
    skynet.send(event, "lua", "subscribe", "player.logout", skynet.self())
    skynet.send(event, "lua", "subscribe", "guild.create", skynet.self())
    skynet.send(event, "lua", "subscribe", "guild.dismiss", skynet.self())
    
    return true
end

-- 事件处理函数
function CMD.on_event(event_name, event_data)
    if event_name == "player.login" then
        -- 玩家登录时自动加入世界频道
        local player_id = event_data.player_id
        local player_name = event_data.player_name
        channel_mgr.join_channel(1, player_id, player_name)  -- 世界频道ID为1
        -- 加载玩家的私聊频道
        channel_mgr.on_player_login(player_id)
    elseif event_name == "player.logout" then
        -- 玩家登出时离开所有频道并清理私聊频道
        local player_id = event_data.player_id
        channel_mgr.on_player_logout(player_id)
    elseif event_name == "guild.create" then
        -- 创建公会频道
        local guild_id = event_data.guild_id
        local guild_name = event_data.guild_name
        local channel_id = channel_mgr.create_channel(guild_channel, guild_name .. "公会频道", "guild", guild_id)
        log.info("Guild channel created for guild %d with ID: %d", guild_id, channel_id)
    elseif event_name == "guild.dismiss" then
        -- 删除公会频道
        local guild_id = event_data.guild_id
        -- 查找并删除对应的公会频道
        for channel_id, channel in pairs(channel_mgr.channels) do
            if channel.channel_type == "guild" and channel:get_guild_id() == guild_id then
                channel_mgr.delete_channel(channel_id)
                log.info("Guild channel deleted for guild %d", guild_id)
                break
            end
        end
    end
end

-- 获取频道列表
function CMD.get_channel_list(player_id)
    return channel_mgr.get_player_channels(player_id)
end

-- 获取频道成员列表
function CMD.get_channel_members(channel_id)
    local channel = channel_mgr.get_channel(channel_id)
    if not channel then
        return nil, "Channel not found"
    end
    return channel:get_members()
end

-- 发送频道消息
function CMD.send_channel_message(channel_id, player_id, content)
    -- 全局限流检查
    if not limiters.global.channel:try_acquire() then
        return false, "Global rate limit exceeded for channel messages"
    end
    
    -- -- 玩家级别限流检查
    -- local player_limiters = limiters.player:get_player_limiters(player_id)
    -- if not player_limiters.channel:try_acquire() then
    --     return false, "Player rate limit exceeded for channel messages"
    -- end
    
    return channel_mgr.send_channel_message(channel_id, player_id, content)
end

function CMD.create_private_channel(player_id, to_player_id)
    channel_mgr.create_private_channel(player_id, to_player_id)
end

-- 发送私聊消息
function CMD.send_private_message(player_id, to_player_id, content)
    -- 全局限流检查
    if not limiters.global.private:try_acquire() then
        return false, "Global rate limit exceeded for private messages"
    end
    
    -- -- 发送者限流检查
    -- local sender_limiters = limiters.player:get_player_limiters(player_id)
    -- if not sender_limiters.private:try_acquire() then
    --     return false, "Sender rate limit exceeded for private messages"
    -- end
    
    return channel_mgr.send_private_channel_message(player_id, to_player_id, content)
end

-- 获取频道历史消息
function CMD.get_channel_history(channel_id, count, player_id)
    -- 全局限流检查
    if not limiters.global.history:try_acquire() then
        return nil, "Global rate limit exceeded for history queries"
    end
    
    -- -- 玩家级别限流检查
    -- local player_limiters = limiters.player:get_player_limiters(player_id)
    -- if not player_limiters.history:try_acquire() then
    --     return nil, "Player rate limit exceeded for history queries"
    -- end
    
    return channel_mgr.get_channel_history(channel_id, count)
end

-- 获取私聊历史消息
function CMD.get_private_history(player_id, other_player_id)
    -- 全局限流检查
    if not limiters.global.history:try_acquire() then
        return nil, "Global rate limit exceeded for history queries"
    end
    
    -- -- 玩家级别限流检查
    -- local player_limiters = limiters.player:get_player_limiters(player_id)
    -- if not player_limiters.history:try_acquire() then
    --     return nil, "Player rate limit exceeded for history queries"
    -- end
    
    -- 查找私聊频道
    for channel_id, channel in pairs(channel_mgr.channels) do
        if channel.channel_type == "private" then
            local other_id = channel:get_other_player_id(player_id)
            if other_id == other_player_id then
                -- 如果玩家删除了聊天，返回空历史
                if channel:is_deleted(player_id) then
                    return {}
                end
                return channel_mgr.get_channel_history(channel_id)
            end
        end
    end
    return nil, "Private channel not found"
end

-- 主服务函数
local function main()
    -- 初始化聊天服务
    CMD.init()
    
    -- 注册服务名
    skynet.register(".chat")
    
    log.info("Chat service started %s", skynet.self())
end

service_wrapper.create_service(main, {
    name = "chat",
    print_stats = true,
})
