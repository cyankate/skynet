package.cpath = "luaclib/?.so"
package.path = "lualib/?.lua;script/?.lua"

if _VERSION ~= "Lua 5.4" then
	error "Use lua 5.4"
end

local socket = require "client.socket"
local proto = require "proto"
local sproto = require "sproto"

-- 客户端配置
local ClientConfig = {
	HOST = "127.0.0.1",
	PORT = 8888,
	RECONNECT_INTERVAL = 5,  -- 重连间隔（秒）
	MAX_RECONNECT_ATTEMPTS = 3
}

-- 客户端状态
local ClientState = {
	fd = nil,
	session = 0,
	last = "",
	host = nil,
	request = nil,
	is_connected = false,
	reconnect_attempts = 0
}

-- 定义所有模块
local NetworkManager = {}
local ProtocolHandler = {}
local MessageHandler = {}
local CommandHandler = {}

-- 协议处理
function ProtocolHandler.send_package(fd, pack)
	local package = string.pack(">s2", pack)
	socket.send(fd, package)
end

function ProtocolHandler.unpack_package(text)
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

function ProtocolHandler.recv_package(_last)
	local result
	result, last = ProtocolHandler.unpack_package(_last)
	if result then
		return result, last
	end
	local r = socket.recv(ClientState.fd)
	if not r then
		return nil, last
	end
	if r == "" then
		error "Server closed"
	end
	return ProtocolHandler.recv_package(last .. r)
end

-- 网络连接管理
function NetworkManager.init()
	ClientState.host = sproto.new(proto.s2c):host "package"
	ClientState.request = ClientState.host:attach(sproto.new(proto.c2s))
end

function NetworkManager.connect()
	ClientState.fd = assert(socket.connect(ClientConfig.HOST, ClientConfig.PORT))
	ClientState.is_connected = true
	ClientState.reconnect_attempts = 0
	print("已连接到服务器")
end

function NetworkManager.disconnect()
	if ClientState.fd then
		socket.close(ClientState.fd)
		ClientState.fd = nil
		ClientState.is_connected = false
	end
end

function NetworkManager.reconnect()
	if ClientState.reconnect_attempts >= ClientConfig.MAX_RECONNECT_ATTEMPTS then
		print("重连次数超过最大限制，退出程序")
		os.exit(1)
	end
	
	print("尝试重新连接...")
	ClientState.reconnect_attempts = ClientState.reconnect_attempts + 1
	NetworkManager.connect()
end

function NetworkManager.send_request(name, args)
	ClientState.session = ClientState.session + 1
	local str = ClientState.request(name, args, ClientState.session)
	ProtocolHandler.send_package(ClientState.fd, str)
	print("Request:", ClientState.session)
end

-- 消息处理
function MessageHandler.print_request(name, args)
	print("REQUEST", name)
	if args then
		for k,v in pairs(args) do
			print(k,v)
		end
	end
end

function MessageHandler.print_response(session, args)
	print("RESPONSE", session)
	if args then
		for k,v in pairs(args) do
			print(k,v)
		end
	end
end

function MessageHandler.handle_server_message(name, args)
	if name == "kicked_out" then
		print("您的账号在其他设备登录，已被强制下线")
		print("原因:", args.reason)
		print("消息:", args.message)
		os.exit(0)
	end
	
	-- 处理其他消息类型...
	print("收到服务器消息:", name)
	if args then
		for k,v in pairs(args) do
			print(k,v)
		end
	end
end

-- 命令处理
function CommandHandler.split(input, delimiter)
	local result = {}
	for match in (input .. delimiter):gmatch("(.-)" .. delimiter) do
		table.insert(result, match)
	end
	return result 
end

function CommandHandler.process_command(cmd)
	if not cmd then return end
	
	if cmd == "quit" then
		NetworkManager.send_request("quit")
	else
		local cmd, args = cmd:match("([^ ]+)%s*(.*)")
		if args then
			args = CommandHandler.split(args, " ")
			for i = 1, #args do
				args[i] = tonumber(args[i]) or args[i]
			end    
		end
		
		if cmd == "login" then
			NetworkManager.send_request(cmd, { account_id = args[1] })
		elseif cmd == "chat" then 
			NetworkManager.send_request("send_channel_message", { channel_id = 1, content = args[1] })
		elseif cmd == "private" then
			NetworkManager.send_request("send_private_message", { to_player_id = args[1], content = args[2] })
		elseif cmd == "change_name" then
			NetworkManager.send_request("change_name", { name = args[1] })
		elseif cmd == "add_item" then
			NetworkManager.send_request("add_item", { item_id = args[1], count = args[2] })
		elseif cmd == "add_friend" then
			NetworkManager.send_request("add_friend", { target_id = args[1], message = args[2] })	
		elseif cmd == "delete_friend" then
			NetworkManager.send_request("delete_friend", { target_id = args[1] })
		elseif cmd == "agree_apply" then
			NetworkManager.send_request("agree_apply", { player_id = args[1] })
		elseif cmd == "reject_apply" then
			NetworkManager.send_request("reject_apply", { player_id = args[1] })
		elseif cmd == "get_friend_list" then
			NetworkManager.send_request("get_friend_list")
		else 
			ProtocolHandler.send_package(ClientState.fd, cmd)
		end 
	end
end

-- 主循环
local function main_loop()
	NetworkManager.init()
	NetworkManager.connect()
	
	while true do
		-- 处理接收到的数据包
		local v
		v, ClientState.last = ProtocolHandler.recv_package(ClientState.last)
		if v then
			local t, name, args, session = ClientState.host:dispatch(v)
			if t == "REQUEST" then
				MessageHandler.handle_server_message(name, args)
			else
				MessageHandler.print_response(session, args)
			end
		end
		
		-- 处理用户输入
		local cmd = socket.readstdin()
		if cmd then
			CommandHandler.process_command(cmd)
		else
			socket.usleep(100)
		end
	end
end

-- 启动客户端
main_loop()
