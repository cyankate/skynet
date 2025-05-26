local socket = require "client.socket"
local proto = require "proto"
local sproto = require "sproto"

local Client = {}
Client.__index = Client

local g_session = 0

function Client.new(id, config)
    local self = setmetatable({}, Client)
    self.id = id
    self.session = 0
    self.last = ""
    self.fd = nil
    self.connected = false
    self.logined = false
    self.last_login_time = 0
    self.last_request_time = nil
    self.account_id = config.account_prefix .. id
    self.player_id = nil
    self.requests_sent = 0
    self.requests_received = 0
    self.host = nil
    self.request = nil
    self.config = config
    return self
end

function Client:connect()
    self.fd = socket.connect(self.config.host, self.config.port)
    if not self.fd then
        return false
    end
    
    self.host = sproto.new(proto.s2c):host "package"
    self.request = self.host:attach(sproto.new(proto.c2s))
    self.connected = true
    return true
end

function Client:disconnect()
    if self.connected and self.fd then
        socket.close(self.fd)
        self.connected = false
    end
end

function Client:send_package(pack)
    if not self.connected then return false end
    local package = string.pack(">s2", pack)
    return socket.send(self.fd, package)
end

function Client:unpack_package(text)
    local size = #text
    if size < 2 then
        return nil, text
    end
    local s = text:byte(1) * 256 + text:byte(2)
    if size < s+2 then
        return nil, text
    end
    return text:sub(3,2+s), text:sub(3+s)
end

function Client:recv_package()
    if not self.connected then return nil end
    local result
    result, self.last = self:unpack_package(self.last)
    if result then
        return result
    end
    local r = socket.recv(self.fd, 100)  -- 非阻塞接收，超时100ms
    if not r then
        return nil
    end
    if r == "" then
        self:disconnect()
        return nil
    end
    self.last = self.last .. r
    return self:recv_package()
end

function Client:send_request(name, args)
    if not self.connected then return false end
    
    g_session = g_session + 1
    local current_session = g_session
    
    local str = self.request(name, args, current_session)
    return self:send_package(str)
end

function Client:process_package(resp)
    if not resp then return end
    
    local t, name, args, response_session = self.host:dispatch(resp)
    
    if t == "REQUEST" then
        if name == "kicked_out" then
            self.logined = false
        elseif name == "login_response" then
            if args.success then
                self.logined = true
                self.player_id = args.player_id
            end
        end
    end
end

function Client:try_login()
    if not self.logined and os.time() - self.last_login_time > 30 then
        self:send_request("login", {account_id = self.account_id})
        self.last_login_time = os.time()
        return true  
    end
    return false 
end

return Client 