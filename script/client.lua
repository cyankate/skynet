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
	reconnect_attempts = 0,
	pending_responses = {}  -- session => callback function
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

-- 发送请求（支持回调函数）
-- callback: function(args) - 收到响应时调用的回调函数，args 是响应数据
function NetworkManager.send_request(name, args, callback)
	ClientState.session = ClientState.session + 1
	local session = ClientState.session
	
	-- 如果有回调函数，保存起来
	if callback then
		ClientState.pending_responses[session] = callback
	end
	
	local str = ClientState.request(name, args, session)
	ProtocolHandler.send_package(ClientState.fd, str)
	print(string.format("Request: %s, session: %d", name, session))
	
	return session
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
	print(string.format("RESPONSE session: %d", session))
	if args then
		for k,v in pairs(args) do
			print(string.format("  %s: %s", k, tostring(v)))
		end
	else
		print("  (no data)")
	end
end

-- 处理响应消息（带回调支持）
function MessageHandler.handle_response(session, args)
	-- 查找并调用对应的回调函数
	local callback = ClientState.pending_responses[session]
	if callback then
		ClientState.pending_responses[session] = nil
		local ok, err = pcall(callback, args)
		if not ok then
			print(string.format("Response callback error for session %d: %s", session, tostring(err)))
		end
	else
		-- 没有回调函数，使用默认打印
		MessageHandler.print_response(session, args)
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
			-- 示例：使用回调函数处理登录响应
			NetworkManager.send_request(cmd, { account_id = args[1] }, function(response)
				if response and response.success then
					print(string.format("登录成功！玩家ID: %s, 玩家名: %s", 
						tostring(response.player_id), response.player_name or "未知"))
				else
					print(string.format("登录失败: %s", response and response.reason or "未知错误"))
				end
			end)
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
			-- 示例：使用回调函数处理好友列表响应
			NetworkManager.send_request("get_friend_list", {}, function(response)
				if response and response.friends then
					print(string.format("好友列表（共 %d 人）:", #response.friends))
					for i, friend in ipairs(response.friends) do
						print(string.format("  %d. ID: %s, 名称: %s", i, 
							tostring(friend.player_id), friend.name or "未知"))
					end
				else
					print("获取好友列表失败")
				end
			end)
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
			local t, name_or_session, args = ClientState.host:dispatch(v)
			if t == "REQUEST" then
				-- 服务器主动推送的消息（如 chat_message, kicked_out 等）
				MessageHandler.handle_server_message(name_or_session, args)
			elseif t == "RESPONSE" then
				-- 响应消息（对应之前发送的请求）
				local session = name_or_session  -- RESPONSE 时第一个返回值是 session
				MessageHandler.handle_response(session, args)
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
