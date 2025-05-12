package.path = package.path .. ";./script/?.lua;./script/utils/?.lua"
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
    
    log.debug("Sending message to client fd " .. fd)
    
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

function handler.open(conf)
    log.info("Gate service opening...")
    
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
                log.info(string.format("Account %s has existing agent, attempting reconnect", args.account_id))
                
                -- 尝试与已有agent重新连接
                local ok, player_info = pcall(skynet.call, account_info.agent, "lua", "reconnect", fd)
                if ok then
                    -- 重连成功
                    c.agent = account_info.agent
                    c.client = fd
                    
                    log.info(string.format("Account %s reconnected to agent %s", args.account_id, account_info.agent))
                    return
                else
                    -- agent服务可能已不存在，继续常规登录流程
                    log.warn(string.format("Reconnect failed for account %s: %s", args.account_id, player_info))
                end
            end
            
            -- 正常登录流程
            local success, agent = skynet.call(loginS, "lua", "login", fd, args.account_id)
            if success then
                -- 绑定连接到 agent 服务
                c.agent = agent
                c.client = fd
                log.info(string.format("Account %s logged in, bound to agent %s", args.account_id, agent))
            else
                -- 登录失败，通知客户端
                log.error(string.format("Login failed for account %s", args.account_id))
                CMD.send_error(fd, 1001, "Login failed")
                socketdriver.close(fd)
            end
        else
            -- 如果已经绑定 agent，则转发消息到 agent
            if c.agent then
                skynet.redirect(c.agent, c.client, "client", 0, skynet.pack(name, args))
            else
                log.error(string.format("Message received before login for fd: %d, name: %s", fd, name))
                CMD.send_error(fd, 1002, "Please login first")
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
    if c and c.agent then
        skynet.send(c.agent, "lua", "disconnect")
    end
    connection[fd] = nil
end

function handler.error(fd, msg)
    log.error(string.format("Client error: fd=%d, msg=%s", fd, msg))
    local c = connection[fd]
    if c and c.agent then
        skynet.send(c.agent, "lua", "disconnect")
    end
    connection[fd] = nil
end

function handler.warning(fd, size)
    log.warn(string.format("Client warning: fd=%d, size=%d", fd, size))
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