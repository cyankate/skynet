local skynet = require "skynet"
require "skynet.manager"

local gate
local agents = {}
local CMD = {}

function CMD.open()
    return skynet.call(gate, "lua", "open", {
        address = "0.0.0.0",
        port = 8888,
    })
end 

local SOCKET = {}
function SOCKET.open(fd, addr)
    local agent = skynet.newservice("agent")
    agents[fd] = addr
    skynet.call(agent, "lua", "start", skynet.self(), fd, addr)
end

function SOCKET.close(fd)
    skynet.error(string.format("[debug] Client %s disconnected", fd))
    local agent = agents[fd]
    agents[fd] = nil
    if agent then
        skynet.send(gate, "lua", "kick", fd)
        skynet.send(agent, "lua", "disconnect")
    end
end

function SOCKET.error(fd, msg)
    skynet.error(string.format("[debug] Client %s error: %s", fd, msg))
    local agent = agents[fd]
    agents[fd] = nil
    if agent then
        skynet.send(gate, "lua", "kick", fd)
        skynet.send(agent, "lua", "disconnect")
    end
end

function SOCKET.warning(fd, size)
    skynet.error(string.format("[debug] Client %s warning: %d bytes", fd, size))
    local agent = agents[fd]
    if agent then
        skynet.send(agent, "lua", "warning", size)
    end
end

skynet.start(function()
    skynet.dispatch("lua", function(_, _, cmd, subcmd, ...)
        if cmd == "socket" then
            local f = SOCKET[subcmd]
            if f then
                skynet.ret(skynet.pack(f(...)))
            else
                skynet.error("Unknown socket command: " .. tostring(subcmd))
            end
        else
            local f = CMD[cmd]
            if f then
                skynet.ret(skynet.pack(f(subcmd, ...)))
            else
                skynet.error("Unknown command: " .. tostring(cmd))
            end
        end
    end)
    gate = skynet.newservice("gate")
    skynet.name(".gate", gate)
end)