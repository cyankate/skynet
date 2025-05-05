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
local connection = {}

skynet.register_protocol {
	name = "client",
	id = skynet.PTYPE_CLIENT,
}

local handler = {}

function handler.open(conf)
    host = sprotoloader.load(1):host "package"
end 

function handler.message(fd, msg, sz)
    local c = connection[fd]
    if not c then 
        log.error("Connection not found for fd:", fd)
        skynet.trash(msg, sz)
        return
    end 
    local data = skynet.tostring(msg, sz)
    local type, name, args, response_func = host:dispatch(data)
    log.debug("message %s %s %s", type, name, args)
    -- local request = skynet.unpack(msg)
    tableUtils.print_table(args)
    --skynet.trash(msg, sz)
    if type == "REQUEST" then
        if name == "login" then
            -- 在单独的协程中处理登录请求
            skynet.fork(function()
                local loginS = skynet.localname(".login")
                local success, agent = skynet.call(loginS, "lua", "login", fd, args.account_id, args.password)
                if success then
                    -- 绑定连接到 agent 服务
                    c.agent = agent
                    c.client = fd
                    log.info(string.format("Account %s logged in, bound to agent %s", args.account_id, agent))
                else
                    -- 登录失败，通知客户端
                    log.error(string.format("Login failed for account %s", args.account_id))
                    socketdriver.close(fd)
                end
            end)
        else
            -- 如果已经绑定 agent，则转发消息到 agent
            if c.agent then
                skynet.redirect(c.agent, c.client, "client", 0, skynet.pack(name, args))
            else
                log.error(string.format("Message received before login for fd: %d", fd))
                skynet.trash(msg, sz)
            end
        end
    end 
end
 
function handler.connect(fd, addr)
    local c = {
        fd = fd,
        ip = addr,
    }
    connection[fd] = c
    gateserver.openclient(fd)
    log.info(string.format("Client connected: fd=%d, ip=%s", fd, addr))
end

function handler.disconnect(fd)
    local c = connection[fd]
    if c then
        connection[fd] = nil
    end
end

function handler.error(fd, msg)
    local c = connection[fd]
    if c then
        connection[fd] = nil
    end
end

function handler.warning(fd, size)
end

gateserver.start(handler)