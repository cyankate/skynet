local skynet = require "skynet"
local log = require "log"
local chat_cache = require "cache.chat_cache"
local channel_cache = require "cache.channel_cache"
local private_channel = require "chat.private_channel"
local guild_channel = require "chat.guild_channel"
local world_channel = require "chat.world_channel"

-- 频道管理器
channel_mgr = {
    channels = {},  -- {channel_id = channel_obj}
    player_channels = {},  -- {player_id = {channel_id = true}}
    private_channels = {},  -- {private_channel_key = channel_id}
    cache = nil,
    private_channel_cache = nil,
    gen_id = 1000,
    player_cache = {},
}

CHANNEL_TYPE = {
    PUBLIC = 1,
    PRIVATE = 2,
    GUILD = 3,
}

function channel_mgr.gen_channel_id()
    local id = channel_mgr.gen_id
    channel_mgr.gen_id = channel_mgr.gen_id + 1
    return id
end

-- 创建频道
function channel_mgr.create_channel(channel_class, channel_id, channel_name, channel_type, ...)
    if not channel_id then 
        channel_id = channel_mgr.gen_channel_id()
    end 
    local channel = channel_class.new(channel_id, channel_name, channel_type, ...)
    channel_mgr.channels[channel_id] = channel
    
    return channel_id
end

function channel_mgr.create_private_channel(player_id, to_player_id)
    local channel_key = channel_mgr.get_private_channel_key(player_id, to_player_id)
    local channel_id = channel_mgr.private_channels[channel_key]
    if channel_id then
        return channel_id
    end
    local dbS = skynet.localname(".db")
    local channel_data = skynet.call(dbS, "lua", "get_player_private", player_id, to_player_id)
    channel_id = channel_mgr.private_channels[channel_key]
    if channel_id then
        return channel_id
    end
    if channel_data then
        channel_id = channel_data.channel_id
    else
        channel_id = channel_mgr.gen_channel_id()
    end 
    
    channel_mgr.create_channel(private_channel, channel_id, "私聊频道", CHANNEL_TYPE.PRIVATE, player_id, to_player_id)
    channel_mgr.private_channels[channel_key] = channel_id

    local private_channel_cache = channel_mgr.private_channel_cache:get(player_id)
    private_channel_cache.data[to_player_id] = {id = channel_id}
    channel_mgr.private_channel_cache:mark_dirty(player_id)

    local channel = channel_mgr.channels[channel_id]
    if not channel_data then 
        skynet.call(dbS, "lua", "create_private_channel", channel:onsave())
    end 

    return channel_id
end 

function channel_mgr.get_private_channel_key(player_id, to_player_id)
    if player_id > to_player_id then
        return to_player_id .. "_" .. player_id
    end
    return player_id .. "_" .. to_player_id
end 

-- 删除频道
function channel_mgr.delete_channel(channel_id)
    local channel = channel_mgr.channels[channel_id]
    if not channel then
        return false, "Channel not found"
    end
    
    -- 通知所有成员
    channel:broadcast_system_message("Channel is being deleted")
    
    -- 从所有玩家的频道列表中移除
    for player_id, _ in pairs(channel.members) do
        if channel_mgr.player_channels[player_id] then
            channel_mgr.player_channels[player_id][channel_id] = nil
        end
    end
    
    -- 删除频道
    channel_mgr.channels[channel_id] = nil
    
    -- 从缓存中删除
    channel_mgr.cache:delete_channel(channel_id)
    
    return true
end

-- 获取频道
function channel_mgr.get_channel(channel_id)
    return channel_mgr.channels[channel_id]
end

-- 玩家加入频道
function channel_mgr.join_channel(channel_id, player_id, player_name)
    local channel = channel_mgr.channels[channel_id]
    if not channel then
        return false, "Channel not found"
    end
    
    local success, err = channel:join(player_id, player_name)
    if success then
        -- 更新玩家频道列表
        if not channel_mgr.player_channels[player_id] then
            channel_mgr.player_channels[player_id] = {}
        end
        channel_mgr.player_channels[player_id][channel_id] = true
    end
    
    return success, err
end

-- 玩家离开频道
function channel_mgr.leave_channel(channel_id, player_id)
    local channel = channel_mgr.channels[channel_id]
    if not channel then
        return false, "Channel not found"
    end
    
    local success, err = channel:leave(player_id)
    if success then
        -- 更新玩家频道列表
        if channel_mgr.player_channels[player_id] then
            channel_mgr.player_channels[player_id][channel_id] = nil
        end
    end
    
    return success, err
end

-- 玩家离开所有频道
function channel_mgr.leave_all_channels(player_id)
    if not channel_mgr.player_channels[player_id] then
        return true
    end
    
    for channel_id, _ in pairs(channel_mgr.player_channels[player_id]) do
        channel_mgr.leave_channel(channel_id, player_id)
    end
    
    channel_mgr.player_channels[player_id] = nil
    return true
end

-- 获取玩家的频道列表
function channel_mgr.get_player_channels(player_id)
    local result = {}
    -- 私聊
    local private_channel_cache = channel_mgr.private_channel_cache:get(player_id)
    for _, v in pairs(private_channel_cache.data) do
        table.insert(result, v)
    end
    -- 公会
    -- 世界
    -- 其他
    return result
end

function channel_mgr.send_private_channel_message(player_id, to_player_id, content)
    local channel_key = channel_mgr.get_private_channel_key(player_id, to_player_id)
    local channel_id = channel_mgr.private_channels[channel_key]
    if not channel_id then
        channel_id = channel_mgr.create_private_channel(player_id, to_player_id)
    end

    local channel = channel_mgr.channels[channel_id]
    if not channel then
        log.error("Channel not found %d", channel_id)
        return false
    end
    channel_mgr.join_channel(channel_id, player_id, player_name)
    channel_mgr.join_channel(channel_id, to_player_id, to_player_name)

    skynet.fork(function()
        local private_channel_cache = channel_mgr.private_channel_cache:get(player_id)
        private_channel_cache.data[to_player_id] = {id = channel_id}
        channel_mgr.private_channel_cache:mark_dirty(player_id)

        local private_channel_cache = channel_mgr.private_channel_cache:get(to_player_id)
        private_channel_cache.data[player_id] = {id = channel_id}
        channel_mgr.private_channel_cache:mark_dirty(to_player_id)
    end)
    
    return channel_mgr.send_channel_message(channel_id, player_id, content)
end 

-- 发送频道消息
function channel_mgr.send_channel_message(channel_id, player_id, content)
    local channel = channel_mgr.channels[channel_id]
    if not channel then
        log.error("Channel not found %d, %d, %s", channel_id, player_id, content)
        return false, "Channel not found"
    end
    if not channel:is_member(player_id) then
        return false, "Not in channel"
    end
    
    local msg = {
        type = "chat",
        channel_id = channel_id,
        channel_name = channel.channel_name,
        sender_id = player_id,
        sender_name = channel.members[player_id].player_name,
        content = content,
        time = os.time()
    }
    
    -- 广播消息
    channel:broadcast_message(msg)
    
    return true
end

-- 获取频道历史消息
function channel_mgr.get_channel_history(channel_id, count)
    service_wrapper.append_cost("get_channel_history")
    count = count or 10
    return channel_mgr.cache:get_channel_messages(channel_id, count)
end

function channel_mgr.on_player_login(player_id)
    local private_channel_cache = channel_mgr.private_channel_cache:get(player_id)
    -- for to_player_id, v in pairs(private_channel_cache.data) do
    --     channel_mgr.create_private_channel(player_id, to_player_id)
    -- end
end 

function channel_mgr.on_player_logout(player_id)

end

-- 初始化管理器
function channel_mgr.init()
    channel_mgr.cache = chat_cache.new()   
    channel_mgr.private_channel_cache = channel_cache.new()
    local function tick()
        skynet.timeout(180 * 100, tick)
        channel_mgr.cache:tick()
        channel_mgr.private_channel_cache:tick()
    end
    skynet.timeout(180 * 100, tick)
    local dbS = skynet.localname(".db")
    local max_channel_id = skynet.call(dbS, "lua", "get_max_channel_id")
    if max_channel_id then  
        channel_mgr.gen_id = max_channel_id + 1
    end
    log.error("channel_mgr.gen_id = %d", channel_mgr.gen_id)
    return true
end

return channel_mgr
