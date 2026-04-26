local gateserver = require "snax.gateserver"
local skynet = require "skynet"
local gate_service = require "gate.gate_service"
local handler = {}

-- 向客户端发送消息
function handler.open(conf)
    return gate_service.handler_open(conf)
end

function handler.message(fd, msg, sz)
    return gate_service.handler_message(fd, msg, sz)
end

function handler.connect(fd, addr)
    gate_service.handler_connect(fd, addr)
    gateserver.openclient(fd)
end

function handler.disconnect(fd)
    return gate_service.handler_disconnect(fd)
end

function handler.error(fd, msg)
    return gate_service.handler_error(fd, msg)
end

function handler.warning(fd, size)
    return gate_service.handler_warning(fd, size)
end

-- 处理指令
function handler.command(cmd, source, ...)
    return gate_service.handler_command(cmd, source, ...)
end

gateserver.start(handler)

skynet.name(".gate", skynet.self())
skynet.send(".logger", "lua", "register_name", "gate")