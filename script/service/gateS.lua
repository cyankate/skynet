local skynet = require "skynet"
local socketdriver = require "skynet.socketdriver"
require "skynet.manager"
local gateserver = require "snax.gateserver"
local sproto = require "sproto"
local sprotoloader = require "sprotoloader"
local tableUtils = require "utils.tableUtils"
local log = require "log"

local host
local sender
local connection = {}

-- 添加映射表
local fd_player_map = {} -- fd => player_id
local player_fd_map = {} -- player_id => fd

skynet.register_protocol {
	name = "client",
	id = skynet.PTYPE_CLIENT,
}

local handler = {}

local message_count = {}

-- 指令处理
local CMD = {}

-- 向客户端发送消息
function CMD.send_message(fd, name, data)
    local c = connection[fd]
    if not c then
        return false
    end
    message_count[name] = (message_count[name] or 0) + 1 
    if message_count[name] % 500 == 0 then
        log.info("send_message name: %s count: %d", name, message_count[name])
    end
    -- 使用 sender 打包消息
    local resp = sender(name, data)
    socketdriver.send(fd, string.pack(">s2", resp))
    
    return true
end

-- 向客户端发送错误信息
function CMD.send_error(fd, code, message)
    return CMD.send_message(fd, "error",{
        code = code,
        message = message
    })
end

-- 关闭客户端连接
function CMD.close_client(fd)
    local c = connection[fd]
    if not c then
        return false
    end
    
    socketdriver.close(fd)
    connection[fd] = nil
    return true
end

-- 主动断开客户端连接（例如被顶号时）
function CMD.kick_client(fd, reason, message)
    local c = connection[fd]
    if not c then
        return false
    end
    
    -- 首先发送被踢下线的消息
    CMD.send_message(fd, "kicked_out", {
        reason = reason or "server_kick",
        message = message or "您已被服务器断开连接"
    })
    
    -- 延迟一小段时间后关闭连接，确保消息能发送到客户端
    skynet.timeout(100, function()
        CMD.close_client(fd)
    end)
    
    return true
end

function CMD.bound_agent(fd, account_key, agent)
    local c = connection[fd]
    if not c then
        return false
    end
    c.account_key = account_key
    c.agent = agent
end 

-- 向所有连接中的客户端广播消息
function CMD.broadcast_message(msg)
    local count = 0
    for fd, _ in pairs(connection) do
        if CMD.send_message(fd, msg) then
            count = count + 1
        end
    end
    log.info(string.format("Broadcasted message to %d clients", count))
    return count
end

-- 注册玩家ID与fd的对应关系
function CMD.register_player(fd, player_id)
    if not fd or not player_id then
        log.error("Invalid parameters for register_player")
        return false
    end
    local c = connection[fd]
    if not c then
        return false
    end
    
    -- 建立双向映射
    c.player_id = player_id
    player_fd_map[player_id] = fd
    
    --log.debug(string.format("Registered player %s with fd %s", player_id, fd))
    return true
end

-- 获取玩家的连接FD
function CMD.get_player_fd(player_id)
    return player_fd_map[player_id]
end

-- 获取多个玩家的连接FD列表
function CMD.get_players_fd(player_ids)
    if type(player_ids) ~= "table" then
        return {}
    end
    
    local result = {}
    for _, player_id in ipairs(player_ids) do
        local fd = player_fd_map[player_id]
        if fd then
            table.insert(result, fd)
        end
    end
    
    return result
end

function CMD.send_to_client(fd, name, data)
    local c = connection[fd]
    if not c then
        --log.error("Connection not found for fd:", fd)
        return false
    end
    return CMD.send_message(fd, name, data)
end

-- 发送消息给指定玩家ID
function CMD.send_to_player(player_id, name, data)
    local fd = player_fd_map[player_id]
    if not fd then
        --log.warning("Player %s not connected, name:%s", player_id, msg.name)
        return false
    end
    
    return CMD.send_message(fd, name, data)
end

-- 发送消息给多个玩家
function CMD.send_to_players(player_ids, name, data)
    if type(player_ids) ~= "table" then
        return 0
    end
    
    local count = 0
    for _, player_id in ipairs(player_ids) do
        if CMD.send_to_player(player_id, name, data) then
            count = count + 1
        end
    end
    return count
end

-- 获取所有在线玩家数量
function CMD.get_online_count()
    local count = 0
    for _ in pairs(player_fd_map) do
        count = count + 1
    end
    
    return count
end

function handler.open(conf)
    -- 加载协议
    local proto = sprotoloader.load(1)
    host = proto:host "package"
    sender = host:attach(sprotoloader.load(2))
    
    log.info("Gate service opened")
end 

function handler.message(fd, msg, sz)
    local c = connection[fd]
    if not c then 
        log.error("Connection not found for fd:", fd)
        skynet.trash(msg, sz)
        return
    end 
    
    -- 解析消息
    local data = skynet.tostring(msg, sz)
    local msg_type, name, args = host:dispatch(data)

    if msg_type == "REQUEST" then
        -- 如果已经绑定 agent，则转发消息到 agent
        if c.agent and c.player_id then
            -- 将玩家ID作为第一个参数传入
            skynet.redirect(c.agent, fd, "client", fd, skynet.pack(c.player_id, name, args))
        else
            local loginS = skynet.localname(".login")
            skynet.redirect(loginS, fd, "client", fd, skynet.pack(name, args))
            -- skynet.trash(msg, sz)
        end
    end 
end
 
function handler.connect(fd, addr)
    log.info(string.format("New client connected: fd=%d, ip=%s", fd, addr))
    local c = {
        fd = fd,
        ip = addr,
    }
    connection[fd] = c
    gateserver.openclient(fd)
end

function handler.disconnect(fd)
    log.info(string.format("Client disconnected: fd=%d", fd))
    local c = connection[fd]
    if c then
        -- 通知agent
        if c.account_key then
            local loginS = skynet.localname(".login")
            skynet.send(loginS, "lua", "disconnect", c.account_key)
        end
    end
    
    connection[fd] = nil
end

function handler.error(fd, msg)
    --log.error(string.format("Client error: fd=%d, msg=%s", fd, msg))
    local c = connection[fd]
    if c then
        -- 通知agent
        if c.account_key then
            local loginS = skynet.localname(".login")
            skynet.send(loginS, "lua", "disconnect", c.account_key)
        end
    end
    
    connection[fd] = nil
end

function handler.warning(fd, size)
    log.warning(string.format("Client warning: fd=%d, size=%d", fd, size))
end

-- 处理指令
function handler.command(cmd, source, ...)
    local f = CMD[cmd]
    if f then
        return f(...)
    else
        log.error("Unknown command:", cmd)
        return false, "Unknown command: " .. cmd
    end
end

gateserver.start(handler)

skynet.name(".gate", skynet.self())