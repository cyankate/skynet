local skynet = require "skynet"
local log = require "log"
require "skynet.manager"
local service_wrapper = require "utils.service_wrapper"
local protocol_handler = require "protocol_handler"

-- 聊天服务数据
local channels = {}     -- 聊天频道 {channel_id = {name=频道名, members={玩家列表}, history={历史消息}}}
local private_msgs = {} -- 私聊消息 {player_id = {历史消息}}

-- 消息最大历史记录数
local MAX_HISTORY = 100

-- 创建新频道
function CMD.create_channel(channel_id, channel_name, creator_id)
    if channels[channel_id] then
        return false, "Channel already exists"
    end
    
    channels[channel_id] = {
        name = channel_name,
        members = {},
        history = {},
        create_time = os.time(),
        creator_id = creator_id
    }
    
    log.info("Channel %s created by player %d", channel_name, creator_id)
    return true
end

-- 加入频道
function CMD.join_channel(channel_id, player_id, player_name)
    if not channels[channel_id] then
        return false, "Channel not found"
    end
    
    local channel = channels[channel_id]
    
    if channel.members[player_id] then
        return true, "Already in channel"
    end
    
    channel.members[player_id] = {
        player_id = player_id,
        player_name = player_name,
        join_time = os.time()
    }
    
    log.info("Player %d joined channel %s", player_id, channel.name)
    
    -- 通知频道内其他成员
    broadcast_to_channel(channel_id, "system", string.format("Player %s has joined the channel", player_name))
    
    return true
end

-- 离开频道
function CMD.leave_channel(channel_id, player_id)
    if not channels[channel_id] then
        return false, "Channel not found"
    end
    
    local channel = channels[channel_id]
    
    if not channel.members[player_id] then
        return false, "Not in channel"
    end
    
    local player_name = channel.members[player_id].player_name
    channel.members[player_id] = nil
    
    log.info("Player %d left channel %s", player_id, channel.name)
    
    -- 通知频道内其他成员
    broadcast_to_channel(channel_id, "system", string.format("Player %s has left the channel", player_name))
    
    return true
end

-- 发送频道消息
function CMD.send_channel_msg(channel_id, player_id, content)
    if not channels[channel_id] then
        return false, "Channel not found"
    end
    
    local channel = channels[channel_id]
    
    if not channel.members[player_id] then
        return false, "Not in channel"
    end
    
    local player_name = channel.members[player_id].player_name
    
    log.debug(string.format("Channel message from %s to channel %s: %s", 
        player_name, channel.name, content))
    
    -- 广播给频道内所有成员
    broadcast_to_channel(channel_id, player_name, content)
    
    return true
end

-- 发送私聊消息
function CMD.send_private_msg(from_id, to_id, content)
    -- 验证发送者
    local player_mapper = skynet.localname(".player_mapper")
    if not player_mapper then
        return false, "Player mapper service not available"
    end
    
    local from_online = skynet.call(player_mapper, "lua", "is_player_online", from_id)
    if not from_online then
        return false, "You are not online"
    end
    
    -- 发送私聊消息
    local success, err = send_private_message(from_id, to_id, content)
    if not success then
        return false, err
    end
    
    log.debug(string.format("Private message from %d to %d: %s", from_id, to_id, content))
    
    return true
end

-- 获取频道列表
function CMD.get_channel_list()
    local result = {}
    
    for id, channel in pairs(channels) do
        local member_count = 0
        for _ in pairs(channel.members) do
            member_count = member_count + 1
        end
        
        table.insert(result, {
            channel_id = id,
            name = channel.name,
            member_count = member_count,
            create_time = channel.create_time
        })
    end
    
    return result
end

-- 获取频道成员列表
function CMD.get_channel_members(channel_id)
    local channel = channels[channel_id]
    if not channel then
        return nil, "Channel does not exist"
    end
    
    local members = {}
    for _, member in pairs(channel.members) do
        table.insert(members, {
            id = member.player_id,
            name = member.player_name,
            join_time = member.join_time
        })
    end
    
    return members
end

-- 内部辅助函数

-- 向频道广播系统消息
function broadcast_to_channel(channel_id, sender_name, content)
    if not channels[channel_id] then
        return false, "Channel not found"
    end
    
    local channel = channels[channel_id]
    local members = {}
    
    -- 收集频道成员ID
    for player_id in pairs(channel.members) do
        table.insert(members, player_id)
    end
    
    -- 创建消息内容
    local msg = {
        type = "channel",
        channel_id = channel_id,
        channel_name = channel.name,
        sender = sender_name,
        content = content,
        timestamp = os.time()
    }
    
    -- 记录到历史消息
    table.insert(channel.history, msg)
    if #channel.history > MAX_HISTORY then
        table.remove(channel.history, 1)
    end
    
    -- 直接使用protocol_handler发送给所有频道成员
    protocol_handler.send_to_players(members, "chat_message", msg)
    
    return true
end

-- 消息过滤
function filter_message(message)
    -- 实际应用中，可以实现敏感词过滤、广告过滤等
    -- 这里简化处理，去除首尾空白并限制长度
    message = string.gsub(message, "^%s*(.-)%s*$", "%1")
    if #message > 1024 then
        message = string.sub(message, 1, 1024) .. "..."
    end
    return message
end

-- 初始化服务
function CMD.init()
    -- 创建全局频道
    CMD.create_channel("global", "Global Channel", 0)
    
    -- 注册事件处理
    local event = skynet.localname(".event")
    skynet.call(event, "lua", "subscribe", "player.login", skynet.self())
    skynet.call(event, "lua", "subscribe", "player.logout", skynet.self())
    
    return true
end

-- 事件处理函数
function CMD.on_event(event_name, event_data)
    log.debug(string.format("on_event %s %s", event_name, tableUtils.serialize_table(event_data)))
    if event_name == "player.login" then
        -- 可以在玩家登录时自动加入全局频道
        local player_id = event_data.player_id
        local player_name = event_data.player_name
        CMD.join_channel("global", player_id, player_name)
    elseif event_name == "player.logout" then
        -- 玩家登出时离开所有频道
        local player_id = event_data.player_id
        CMD.leave_channel("global", player_id)
    end
end

-- 获取频道历史消息
function CMD.get_channel_history(channel_id, count)
    if not channels[channel_id] then
        return nil, "Channel not found"
    end
    
    count = count or MAX_HISTORY
    local history = channels[channel_id].history
    local result = {}
    
    -- 从最新的消息开始，最多返回count条
    for i = #history, math.max(1, #history - count + 1), -1 do
        table.insert(result, history[i])
    end
    
    return result
end

-- 获取私聊历史消息
function CMD.get_private_history(player_id, other_id, count)
    if not private_msgs[player_id] then
        return {}
    end
    
    count = count or MAX_HISTORY
    local result = {}
    
    -- 筛选与指定玩家的私聊消息
    for i, msg in ipairs(private_msgs[player_id]) do
        if (msg.from_id == player_id and msg.to_id == other_id) or
           (msg.from_id == other_id and msg.to_id == player_id) then
            table.insert(result, msg)
            if #result >= count then
                break
            end
        end
    end
    
    return result
end

-- 系统公告
function CMD.system_announcement(message, target_players)
    local msg = {
        type = "system",
        content = message,
        timestamp = os.time()
    }
    
    if target_players then
        -- 发送给指定玩家
        return protocol_handler.send_to_players(target_players, "chat_message", msg)
    else
        -- 广播给所有在线玩家
        return protocol_handler.broadcast("chat_message", msg)
    end
end

-- 清理玩家聊天数据
function CMD.cleanup_player_data(player_id)
    -- 从所有频道中移除玩家
    for channel_id, channel in pairs(channels) do
        if channel.members[player_id] then
            channel.members[player_id] = nil
            log.info("Removed player %d from channel %s during cleanup", player_id, channel.name)
        end
    end
    
    -- 清理私聊历史
    private_msgs[player_id] = nil
    
    return true
end

-- 发送私聊消息的内部实现
local function send_private_message(from_id, to_id, content)
    -- 检查目标玩家是否存在
    local player_mapper = skynet.localname(".player_mapper")
    if not player_mapper then
        return false, "Player mapper service not available"
    end
    
    local is_online = skynet.call(player_mapper, "lua", "is_player_online", to_id)
    if not is_online then
        return false, "Player is not online"
    end
    
    -- 创建消息内容
    local msg = {
        type = "private",
        from_id = from_id,
        to_id = to_id,
        content = content,
        timestamp = os.time()
    }
    
    -- 初始化历史记录容器
    if not private_msgs[from_id] then
        private_msgs[from_id] = {}
    end
    if not private_msgs[to_id] then
        private_msgs[to_id] = {}
    end
    
    -- 添加到发送者历史
    table.insert(private_msgs[from_id], msg)
    if #private_msgs[from_id] > MAX_HISTORY then
        table.remove(private_msgs[from_id], 1)
    end
    
    -- 添加到接收者历史
    table.insert(private_msgs[to_id], msg)
    if #private_msgs[to_id] > MAX_HISTORY then
        table.remove(private_msgs[to_id], 1)
    end
    
    -- 直接使用protocol_handler发送给接收者
    protocol_handler.send_to_player(to_id, "chat_message", msg)
    
    return true
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
})
