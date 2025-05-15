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

-- 指令处理
local CMD = {}

-- 向客户端发送消息
function CMD.send_message(fd, msg)
    local c = connection[fd]
    if not c then
        log.error("Connection not found for fd:", fd)
        return false
    end
    
    --log.debug("Sending message to client fd " .. fd)
    
    -- 序列化消息
    local name = msg.name or "response"
    local args = msg.data or {}
    
    -- 使用sproto协议打包
    local resp = sender(name, args)
    
    -- 发送到客户端
    socketdriver.send(fd, string.pack(">s2", resp))
    
    return true
end

-- 向客户端发送错误信息
function CMD.send_error(fd, code, message)
    return CMD.send_message(fd, {
        name = "error",
        data = {
            code = code,
            message = message
        }
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
    CMD.send_message(fd, {
        name = "kicked_out",
        data = {
            reason = reason or "server_kick",
            message = message or "您已被服务器断开连接"
        }
    })
    
    -- 延迟一小段时间后关闭连接，确保消息能发送到客户端
    skynet.timeout(100, function()
        CMD.close_client(fd)
    end)
    
    return true
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

-- 向特定列表的客户端广播消息
function CMD.broadcast_to_list(fds, msg)
    if type(fds) ~= "table" then
        return 0
    end
    
    local count = 0
    for _, fd in ipairs(fds) do
        if CMD.send_message(fd, msg) then
            count = count + 1
        end
    end
    log.info(string.format("Broadcasted message to %d clients in list", count))
    return count
end

-- 注册玩家ID与fd的对应关系
function CMD.register_player(fd, player_id)
    if not fd or not player_id then
        log.error("Invalid parameters for register_player")
        return false
    end
    
    -- 如果玩家已有连接，先清理旧连接
    if player_fd_map[player_id] then
        local old_fd = player_fd_map[player_id]
        fd_player_map[old_fd] = nil
        log.debug(string.format("Player %s was already connected with fd %s, now connected with %s", 
            player_id, old_fd, fd))
    end
    
    -- 如果连接已绑定其他玩家，先解绑
    if fd_player_map[fd] and fd_player_map[fd] ~= player_id then
        local old_player = fd_player_map[fd]
        player_fd_map[old_player] = nil
        log.debug(string.format("Fd %s was bound to player %s, now bound to player %s", 
            fd, old_player, player_id))
    end
    
    -- 建立双向映射
    fd_player_map[fd] = player_id
    player_fd_map[player_id] = fd
    
    log.info(string.format("Registered player %s with fd %s", player_id, fd))
    return true
end

-- 解除玩家与FD的绑定
function CMD.unregister_player(player_id)
    if not player_id then
        log.error("Invalid player_id for unregister_player")
        return false
    end
    
    local fd = player_fd_map[player_id]
    if fd then
        fd_player_map[fd] = nil
        player_fd_map[player_id] = nil
        log.info(string.format("Unregistered player %s with fd %s", player_id, fd))
        return true
    else
        log.warning(string.format("Player %s was not registered", player_id))
        return false
    end
end

-- 解除FD与玩家的绑定
function CMD.unregister_fd(fd)
    if not fd then
        log.error("Invalid fd for unregister_fd")
        return false
    end
    
    local player_id = fd_player_map[fd]
    if player_id then
        player_fd_map[player_id] = nil
        fd_player_map[fd] = nil
        log.info(string.format("Unregistered fd %s for player %s", fd, player_id))
        return true
    else
        log.warning(string.format("Fd %s was not registered to any player", fd))
        return false
    end
end

-- 获取玩家的连接FD
function CMD.get_player_fd(player_id)
    return player_fd_map[player_id]
end

-- 获取连接FD对应的玩家ID
function CMD.get_fd_player(fd)
    return fd_player_map[fd]
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

-- 发送消息给指定玩家ID
function CMD.send_to_player(player_id, msg)
    local fd = player_fd_map[player_id]
    if not fd then
        log.warning("Player %s not connected", player_id)
        return false
    end
    
    return CMD.send_message(fd, msg)
end

-- 发送消息给多个玩家
function CMD.send_to_players(player_ids, msg)
    if type(player_ids) ~= "table" then
        return 0
    end
    
    local count = 0
    for _, player_id in ipairs(player_ids) do
        if CMD.send_to_player(player_id, msg) then
            count = count + 1
        end
    end
    
    -- log.info(string.format("Sent message to %d players out of %d requested", 
    --     count, #player_ids))
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
    local type, name, args, response_func = host:dispatch(data)
    log.debug("message %s %s", name, tableUtils.serialize_table(args))
    
    if type == "REQUEST" then
        if name == "login" then
            local loginS = skynet.localname(".login")
            
            -- 尝试查找账号信息
            local account_info = skynet.call(loginS, "lua", "find_account", args.account_id)
            
            if account_info and account_info.agent and account_info.logout then
                -- 账号已有agent服务，尝试重连
                log.debug(string.format("Account %s has existing agent, attempting reconnect", args.account_id))
                
                -- 尝试与已有agent重新连接，传递账号key
                local ok = skynet.call(loginS, "lua", "reconnect", args.account_id, fd)
                if ok then
                    -- 重连成功
                    c.agent = account_info.agent
                    c.client = fd
                    c.account_key = args.account_id
                    
                    log.info(string.format("Account %s reconnected to agent %s", args.account_id, account_info.agent))
                    return
                else
                    -- agent服务可能已不存在，继续常规登录流程
                    log.warning(string.format("Reconnect failed for account %s: %s", args.account_id, player_info))
                end
            end
            
            -- 正常登录流程
            local success, agent, error_msg, token = skynet.call(loginS, "lua", "login", 
                fd, 
                args.account_id, 
                c.ip,                   -- 传递客户端IP地址
                args.device_id or "unknown" -- 传递设备ID
            )
            
            if success then
                -- 登录成功，设置agent和连接信息
                c.agent = agent
                c.client = fd
                c.account_key = args.account_id
                
                log.info(string.format("Login success for account %s, agent: %s", args.account_id, agent))
            else
                -- 登录失败，返回错误信息
                log.warning(string.format("Login failed for account %s: %s", args.account_id, error_msg or "Unknown error"))
            end
            return
        elseif name == "token_login" then
            -- 使用令牌登录
            local loginS = skynet.localname(".login")
            
            if not args.token then
                log.error("Token is nil")
                return
            end
            
            -- 调用令牌登录
            local success, agent, error_msg, new_token = skynet.call(loginS, "lua", "token_login",
                args.token,
                fd,
                c.ip,
                args.device_id or "unknown"
            )
            
            if success then
                -- 绑定连接到 agent 服务
                c.agent = agent
                c.client = fd
                
                log.debug(string.format("Token login successful, bound to agent %s", agent))
            else
                -- 登录失败，通知客户端
                log.error(string.format("Token login failed: %s", error_msg or "Unknown error"))
            end
        else
            -- 如果已经绑定 agent，则转发消息到 agent
            if c.agent then
                skynet.redirect(c.agent, c.client, "client", 0, skynet.pack(name, args))
            else
                log.error(string.format("Message received before login for fd: %d, name: %s", fd, name))
                skynet.trash(msg, sz)
            end
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
        
        -- 移除玩家ID与fd的映射
        local player_id = fd_player_map[fd]
        if player_id then
            player_fd_map[player_id] = nil
            fd_player_map[fd] = nil
            log.debug(string.format("Removed mapping for player %s due to disconnect", player_id))
        end
    end
    
    connection[fd] = nil
end

function handler.error(fd, msg)
    log.error(string.format("Client error: fd=%d, msg=%s", fd, msg))
    local c = connection[fd]
    if c then
        -- 移除玩家ID与fd的映射
        local player_id = fd_player_map[fd]
        if player_id then
            player_fd_map[player_id] = nil
            fd_player_map[fd] = nil
            log.debug(string.format("Removed mapping for player %s due to error", player_id))
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