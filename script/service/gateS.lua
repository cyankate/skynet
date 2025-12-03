local skynet = require "skynet"
local socketdriver = require "skynet.socketdriver"
require "skynet.manager"
local gateserver = require "snax.gateserver"
local sproto = require "sproto"
local sprotoloader = require "sprotoloader"
local tableUtils = require "utils.tableUtils"
local log = require "log"
local proto_builder = require "utils.proto_builder"

local host
local sender
local connection = {}

-- 添加映射表
local fd_player_map = {} -- fd => player_id
local player_fd_map = {} -- player_id => fd

-- sproto RPC 响应缓存：fd -> session -> response_func
-- 当收到客户端请求时，由 host:dispatch 生成 response_func，保存在这里；
-- 业务处理完后，通过 CMD.rpc_response 再由 gateS 调用 response_func 打包并发送给客户端。
local pending_responses = {}  -- pending_responses[fd][session] = response_func

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
    
    if not name then
        log.error("send_message: 协议名为空, fd=%d", fd)
        return false
    end
    
    -- 统一验证：获取发送给客户端的协议 schema 并验证
    local schema = proto_builder.get_send_to_client_schema(name)
    if schema then
        local ok, err_msg = proto_builder.validate(name, data, schema)
        if not ok then
            log.error("协议验证失败: fd=%d, player_id=%s, protocol=%s, error=%s, data=%s",
                fd, tostring(c.player_id), name, err_msg,
                data and tableUtils.serialize_table(data) or "nil")
            return false
        end
    else
        -- schema 未注册，记录警告但不阻止发送（兼容性考虑）
        log.debug("协议 schema 未注册: protocol=%s, fd=%d", name, fd)
    end
    
    message_count[name] = (message_count[name] or 0) + 1 
    if message_count[name] % 500 == 0 then
        log.info("send_message name: %s count: %d", name, message_count[name])
    end
    
    -- 使用 sender 打包消息
    local ok, resp = pcall(sender, name, data)
    
    if not ok then
        log.error("协议打包失败: fd=%d, protocol=%s, error=%s, data=%s",
            fd, name, tostring(resp),
            data and tableUtils.serialize_table(data) or "nil")
        return false
    end
    
    if not resp then
        log.warning("协议打包返回空: fd=%d, protocol=%s", fd, name)
        return false
    end
    
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

-- 使用 sproto 的 response 机制回复客户端
-- fd      : 客户端连接 fd
-- session : sproto 请求的 session
-- data    : 按该协议 response 定义的 Lua 表
function CMD.rpc_response(fd, session, data)
    local c = connection[fd]
    if not c then
        log.error("rpc_response: connection not found for fd:", fd)
        return false
    end

    local pr = pending_responses[fd]
    if not pr then
        log.error("rpc_response: no pending responses for fd:", fd)
        return false
    end

    local response_func = pr[session]
    if not response_func then
        log.error("rpc_response: no response_func for fd:%d session:%s", fd, tostring(session))
        return false
    end

    -- 调用 sproto 生成响应二进制
    local ok, resp = pcall(response_func, data)
    pr[session] = nil

    if not ok then
        log.error("rpc_response: response_func error for fd:%d session:%s, err:%s",
            fd, tostring(session), tostring(resp))
        return false
    end

    if not resp then
        -- 允许业务选择不回包
        return true
    end

    socketdriver.send(fd, string.pack(">s2", resp))
    return true
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
    
    -- 解析消息（sproto 解包）
    local data = skynet.tostring(msg, sz)
    -- msg_type : "REQUEST" / "RESPONSE"
    -- name     : 协议名（REQUEST）或 session（RESPONSE）
    -- args     : 解析后的参数表
    -- response_func : 对于 RPC 请求，提供的回复打包函数
    -- ud, session   : 这里暂不使用 ud，只记录 session 用于 RPC
    local ok, msg_type, name, args, response_func, _, session = pcall(host.dispatch, host, data)
    
    if not ok then
        -- sproto 解析失败
        log.error("协议解析失败: fd=%d, player_id=%s, error=%s, data_size=%d",
            fd, tostring(c.player_id), tostring(msg_type), sz)
        --CMD.send_error(fd, 1001, "协议格式错误")
        return
    end
    
    if not msg_type then
        log.warning("收到无效消息: fd=%d, player_id=%s, data_size=%d",
            fd, tostring(c.player_id), sz)
        return
    end

    if msg_type == "REQUEST" then
        -- 记录接收到的协议信息（用于调试）
        if not name then
            log.error("协议名为空: fd=%d, player_id=%s", fd, tostring(c.player_id))
            CMD.send_error(fd, 1002, "协议名无效")
            return
        end
        
        -- 统一验证：获取接收客户端消息的协议 schema 并验证
        local schema = proto_builder.get_receive_from_client_schema(name)
        if schema and args then
            local ok, err_msg = proto_builder.validate(name, args, schema)
            if not ok then
                log.error("协议验证失败: fd=%d, player_id=%s, protocol=%s, error=%s, args=%s",
                    fd, tostring(c.player_id), name, err_msg,
                    tableUtils.serialize_table(args))
                CMD.send_error(fd, 1003, "协议字段验证失败: " .. err_msg)
                return
            end
        end
        
        -- 记录接收到的协议信息（用于调试）
        if args and type(args) == "table" then
            log.debug("收到协议: fd=%d, player_id=%s, protocol=%s, args=%s",
                fd, tostring(c.player_id), name, tableUtils.serialize_table(args))
        else
            log.debug("收到协议: fd=%d, player_id=%s, protocol=%s, args=nil",
                fd, tostring(c.player_id), name)
        end
        
        -- 如果是 RPC 请求（带 session），缓存 response_func，后续由业务处理完再调用
        if response_func and session then
            local pr = pending_responses[fd]
            if not pr then
                pr = {}
                pending_responses[fd] = pr
            end
            pr[session] = response_func
        end

        -- 如果已经绑定 agent，则转发消息到 agent
        if c.agent and c.player_id then
            skynet.redirect(c.agent, fd, "client", fd, skynet.pack(c.player_id, name, args, session))
        else
            local loginS = skynet.localname(".login")
            -- login 阶段还没有 player_id，只传 name/args/session
            skynet.redirect(loginS, fd, "client", fd, skynet.pack(name, args, session))
            -- skynet.trash(msg, sz)
        end
    elseif msg_type == "RESPONSE" then
        -- 处理服务器响应（客户端发来的响应，通常不需要处理）
        log.debug("收到响应: fd=%d, session=%s", fd, tostring(name))
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
skynet.send(".logger", "lua", "register_name", "gate")