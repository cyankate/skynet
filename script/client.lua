package.cpath = "luaclib/?.so"
package.path = "lualib/?.lua;script/?.lua"

if _VERSION ~= "Lua 5.4" then
	error "Use lua 5.4"
end

local socket = require "client.socket"
local proto = require "proto"
local sproto = require "sproto"

local host = sproto.new(proto.s2c):host "package"
local request = host:attach(sproto.new(proto.c2s))

local fd = assert(socket.connect("127.0.0.1", 8888))

local function send_package(fd, pack)
	local package = string.pack(">s2", pack)
	socket.send(fd, package)
end

local function unpack_package(text)
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

local function recv_package(_last)
	local result
	result, last = unpack_package(_last)
	if result then
		return result, last
	end
	local r = socket.recv(fd)
	if not r then
		return nil, last
	end
	if r == "" then
		error "Server closed"
	end
	return recv_package(last .. r)
end

local session = 0

local function send_request(name, args)
	session = session + 1
	local str = request(name, args, session)
	send_package(fd, str)
	print("Request:", session)
end

local last = ""

local function print_request(name, args)
	print("REQUEST", name)
	if args then
		for k,v in pairs(args) do
			print(k,v)
		end
	end
end

local function print_response(session, args)
	print("RESPONSE", session)
	if args then
		for k,v in pairs(args) do
			print(k,v)
		end
	end
end

local function print_package(t, ...)
	if t == "REQUEST" then
		print_request(...)
	else
		assert(t == "RESPONSE")
		print_response(...)
	end
end

-- 处理服务器消息，添加对被顶号消息的处理
local function handle_server_message(name, args)
    if name == "kicked_out" then
        print("您的账号在其他设备登录，已被强制下线")
        print("原因:", args.reason)
        print("消息:", args.message)
        
        -- 这里可以添加额外的客户端逻辑，如自动重新登录尝试等
        -- 在实际游戏中，可能需要弹出对话框提示用户
        
        -- 终止客户端
        os.exit(0)
    end
    
    -- 处理其他消息类型...
end

local function dispatch_package()
	while true do
		local v
		v, last = recv_package(last)
		if not v then
			break
		end

		print_package(host:dispatch(v))
	end
end

function ssplit(input, delimiter)
    local result = {}
    for match in (input .. delimiter):gmatch("(.-)" .. delimiter) do
        table.insert(result, match)
    end
    return result 
end

send_request("login", {account_id = "tom"})

-- socket.usleep(30000)
-- send_request("signin", {idx = 1})

--send_package(fd, "hello")
while true do
	dispatch_package()
	local cmd = socket.readstdin()
	if cmd then
		if cmd == "quit" then
			send_request("quit")
		else
			local cmd, args = cmd:match("([^ ]+) (.*)")
			if args then
				args = ssplit(args, " ")
				for i = 1, #args do
					args[i] = tonumber(args[i]) or args[i]
				end	
			end
			if cmd == "login" then
				send_request(cmd, { account_id = args[1] })
			elseif cmd == "chat" then 
				send_request("send_channel_message", { channel_id = "global", content = args[1] })
			else 
				send_package(fd, cmd)
			end 
		end
	else
		socket.usleep(100)
	end
end
