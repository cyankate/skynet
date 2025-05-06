package.path = package.path .. ";./script/?.lua;./script/utils/?.lua"
local skynet = require "skynet"
local log = require "log"
require "skynet.manager"

local CMD = {}
local channels = {}     -- 聊天频道 {channel_id = {name=频道名, members={玩家列表}, history={历史消息}}}
local private_msgs = {} -- 私聊消息 {player_id = {历史消息}}
local player_agents = {} -- 玩家对应的agent服务 {player_id = agent_handle}

-- 消息最大历史记录数
local MAX_HISTORY = 100

-- 建立玩家和Agent服务的映射
function CMD.register_player(player_id, agent)
    player_agents[player_id] = agent
    log.info("Player %d registered in chat service with agent %s", player_id, agent)
    return true
end

-- 取消玩家注册
function CMD.unregister_player(player_id)
    player_agents[player_id] = nil
    log.info("Player %d unregistered from chat service", player_id)
    
    -- 离开所有频道
    for channel_id, channel in pairs(channels) do
        if channel.members[player_id] then
            channel.members[player_id] = nil
            -- 通知频道其他成员该玩家离开
            broadcast_to_channel(channel_id, "system", string.format("Player %d has left the channel", player_id))
        end
    end
    
    return true
end

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
    local channel = channels[channel_id]
    if not channel then
        return false, "Channel does not exist"
    end
    
    channel.members[player_id] = {
        id = player_id,
        name = player_name,
        join_time = os.time()
    }
    
    -- 通知频道其他成员新玩家加入
    broadcast_to_channel(channel_id, "system", string.format("Player %s has joined the channel", player_name))
    
    log.info("Player %d joined channel %s", player_id, channel.name)
    return true
end

-- 离开频道
function CMD.leave_channel(channel_id, player_id)
    local channel = channels[channel_id]
    if not channel then
        return false, "Channel does not exist"
    end
    
    if not channel.members[player_id] then
        return false, "Player not in channel"
    end
    
    local player_name = channel.members[player_id].name
    channel.members[player_id] = nil
    
    -- 通知频道其他成员该玩家离开
    broadcast_to_channel(channel_id, "system", string.format("Player %s has left the channel", player_name))
    
    log.info("Player %d left channel %s", player_id, channel.name)
    return true
end

-- 发送频道消息
function CMD.send_channel_msg(channel_id, player_id, message)
    log.debug(string.format("send_channel_msg %s %s %s", channel_id, player_id, message))
    local channel = channels[channel_id]
    if not channel then
        return false, "Channel does not exist"
    end
    if not channel.members[player_id] then
        return false, "Player not in channel"
    end
    
    -- 过滤消息内容
    message = filter_message(message)
    
    local player_name = channel.members[player_id].name
    local msg = {
        type = "channel",
        channel_id = channel_id,
        from_id = player_id,
        from_name = player_name,
        content = message,
        timestamp = os.time()
    }
    
    -- 保存到历史记录
    table.insert(channel.history, msg)
    if #channel.history > MAX_HISTORY then
        table.remove(channel.history, 1)
    end
    
    -- 广播给频道内所有玩家
    for member_id, _ in pairs(channel.members) do
        local agent = player_agents[member_id]
        if agent then
            skynet.send(agent, "lua", "chat_message", msg)
        end
    end
    
    log.info("Channel message from player %d to channel %s: %s", player_id, channel.name, message)
    return true
end

-- 发送私聊消息
function CMD.send_private_msg(from_id, to_id, message)
    -- 检查目标玩家是否在线
    if not player_agents[to_id] then
        return false, "Target player not online"
    end
    
    -- 过滤消息内容
    message = filter_message(message)
    
    -- 获取玩家名称
    local from_name = get_player_name(from_id)
    local to_name = get_player_name(to_id)
    
    local msg = {
        type = "private",
        from_id = from_id,
        from_name = from_name,
        to_id = to_id,
        to_name = to_name,
        content = message,
        timestamp = os.time()
    }
    
    -- 保存到发送者的历史记录
    if not private_msgs[from_id] then
        private_msgs[from_id] = {}
    end
    table.insert(private_msgs[from_id], msg)
    if #private_msgs[from_id] > MAX_HISTORY then
        table.remove(private_msgs[from_id], 1)
    end
    
    -- 保存到接收者的历史记录
    if not private_msgs[to_id] then
        private_msgs[to_id] = {}
    end
    table.insert(private_msgs[to_id], msg)
    if #private_msgs[to_id] > MAX_HISTORY then
        table.remove(private_msgs[to_id], 1)
    end
    
    -- 发送消息给接收者
    local agent = player_agents[to_id]
    if agent then
        skynet.send(agent, "lua", "chat_message", msg)
    end
    
    log.info("Private message from player %d to player %d: %s", from_id, to_id, message)
    return true
end

-- 获取频道历史消息
function CMD.get_channel_history(channel_id, count)
    local channel = channels[channel_id]
    if not channel then
        return nil, "Channel does not exist"
    end
    
    count = count or MAX_HISTORY
    local history = {}
    local start = math.max(1, #channel.history - count + 1)
    
    for i = start, #channel.history do
        table.insert(history, channel.history[i])
    end
    
    return history
end

-- 获取私聊历史消息
function CMD.get_private_history(player_id, other_id, count)
    if not private_msgs[player_id] then
        return {}
    end
    
    count = count or MAX_HISTORY
    local history = {}
    
    for _, msg in ipairs(private_msgs[player_id]) do
        if (msg.from_id == other_id or msg.to_id == other_id) then
            table.insert(history, msg)
            if #history >= count then
                break
            end
        end
    end
    
    return history
end

-- 广播系统消息给所有在线玩家
function CMD.broadcast_system_msg(message)
    local msg = {
        type = "system",
        from_id = 0,
        from_name = "System",
        content = message,
        timestamp = os.time()
    }
    
    for player_id, agent in pairs(player_agents) do
        skynet.send(agent, "lua", "chat_message", msg)
    end
    
    log.info("System broadcast: %s", message)
    return true
end

-- 获取频道列表
function CMD.get_channel_list()
    local result = {}
    for id, channel in pairs(channels) do
        table.insert(result, {
            id = id,
            name = channel.name,
            member_count = get_table_size(channel.members),
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
            id = member.id,
            name = member.name,
            join_time = member.join_time
        })
    end
    
    return members
end

-- 内部辅助函数

-- 向频道广播系统消息
function broadcast_to_channel(channel_id, from_name, message)
    local channel = channels[channel_id]
    if not channel then
        return
    end
    
    local msg = {
        type = "channel",
        channel_id = channel_id,
        from_id = 0,
        from_name = from_name or "System",
        content = message,
        timestamp = os.time()
    }
    
    -- 保存到历史记录
    table.insert(channel.history, msg)
    if #channel.history > MAX_HISTORY then
        table.remove(channel.history, 1)
    end
    
    -- 广播给频道内所有玩家
    for member_id, _ in pairs(channel.members) do
        local agent = player_agents[member_id]
        if agent then
            skynet.send(agent, "lua", "chat_message", msg)
        end
    end
end

-- 获取玩家名称
function get_player_name(player_id)
    -- 实际应用中可能需要从玩家服务获取玩家名称
    -- 这里简化处理
    return "Player_" .. player_id
end

-- 获取表的大小
function get_table_size(t)
    local count = 0
    for _, _ in pairs(t) do
        count = count + 1
    end
    return count
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
    
    log.info("Chat service initialized")
    return true
end

-- 事件处理函数
function CMD.on_event(event_name, event_data)
    if event_name == "player.login" then
        CMD.register_player(event_data.player_id, event_data.agent)
        -- 可以在玩家登录时自动加入全局频道
        local player_id = event_data.player_id
        local player_name = get_player_name(player_id)
        CMD.join_channel("global", player_id, player_name)
    elseif event_name == "player.logout" then
        -- 玩家登出时取消注册
        local player_id = event_data.player_id
        CMD.unregister_player(player_id)
    end
end

-- 服务启动
skynet.start(function()
    -- 初始化聊天服务
    CMD.init()
    
    -- 注册消息分发
    skynet.dispatch("lua", function(session, source, cmd, ...)
        local f = CMD[cmd]
        if f then
            if session == 0 then
                f(...)
            else
                skynet.ret(skynet.pack(f(...)))
            end
        else
            log.error("Unknown command: %s", cmd)
            if session ~= 0 then
                skynet.ret(skynet.pack(false, "Unknown command: " .. cmd))
            end
        end
    end)
    
    log.info("Chat service started %s", skynet.self())
end)
