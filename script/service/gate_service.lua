local skynet = require "skynet"
local socketdriver = require "skynet.socketdriver"
local sprotoloader = require "sprotoloader"
local tableUtils = require "utils.tableUtils"
local log = require "log"
local proto_builder = require "utils.proto_builder"
local service_ctx = require "runtime.service_ctx"

local M = service_ctx.get("gate.gate", {})
M.connection = M.connection or {}
M.fd_player_map = M.fd_player_map or {}
M.player_fd_map = M.player_fd_map or {}
M.pending_responses = M.pending_responses or {}
M.message_count = M.message_count or {}

local host = M.host
local sender = M.sender
local connection = M.connection
local player_fd_map = M.player_fd_map
local pending_responses = M.pending_responses
local message_count = M.message_count

skynet.register_protocol({
    name = "client",
    id = skynet.PTYPE_CLIENT,
})

function M.reload_proto()
    proto_builder.clear_schemas()
    local ok1, proto_or_err = pcall(sprotoloader.load, 1)
    if not ok1 or not proto_or_err then
        log.error("reload_proto failed on c2s: %s", tostring(proto_or_err))
        return false, tostring(proto_or_err)
    end
    local ok2, s2c_or_err = pcall(sprotoloader.load, 2)
    if not ok2 or not s2c_or_err then
        log.error("reload_proto failed on s2c: %s", tostring(s2c_or_err))
        return false, tostring(s2c_or_err)
    end
    local new_host = proto_or_err:host("package")
    local new_sender = new_host:attach(s2c_or_err)
    host = new_host
    sender = new_sender
    M.host = host
    M.sender = sender
    log.info("gate proto reloaded")
    return true
end

function M.send_message(fd, name, data)
    local c = connection[fd]
    if not c then
        return false
    end
    if not name then
        log.error("send_message: 协议名为空, fd=%d", fd)
        return false
    end
    local schema = proto_builder.get_send_to_client_schema(name)
    if schema then
        local ok, err_msg = proto_builder.validate(name, data, schema)
        if not ok then
            log.error("协议验证失败: fd=%d, player_id=%s, protocol=%s, error=%s, data=%s",
                fd, tostring(c.player_id), name, err_msg, data and tableUtils.serialize_table(data) or "nil")
            return false
        end
    end
    message_count[name] = (message_count[name] or 0) + 1
    local ok, resp = pcall(sender, name, data)
    if not ok or not resp then
        return false
    end
    socketdriver.send(fd, string.pack(">s2", resp))
    return true
end

function M.send_error(fd, code, message)
    return M.send_message(fd, "error", { code = code, message = message })
end

function M.close_client(fd)
    local c = connection[fd]
    if not c then
        return false
    end
    log.info("client closed, fd=%d, account_key=%s", fd, c.account_key)
    socketdriver.close(fd)
    connection[fd] = nil
    return true
end

function M.kick_client(fd, reason, message)
    local c = connection[fd]
    if not c then
        return false
    end
    M.send_message(fd, "kicked_out", {
        reason = reason or "server_kick",
        message = message or "您已被服务器断开连接",
    })
    skynet.timeout(100, function()
        M.close_client(fd)
    end)
    return true
end

function M.bound_agent(fd, account_key, agent)
    local c = connection[fd]
    if not c then
        return false
    end
    c.account_key = account_key
    c.agent = agent
end

function M.broadcast_message(msg)
    local count = 0
    for fd, _ in pairs(connection) do
        if M.send_message(fd, msg) then
            count = count + 1
        end
    end
    return count
end

function M.register_player(fd, player_id)
    if not fd or not player_id then
        return false
    end
    local c = connection[fd]
    if not c then
        return false
    end
    c.player_id = player_id
    player_fd_map[player_id] = fd
    return true
end

function M.get_player_fd(player_id)
    return player_fd_map[player_id]
end

function M.get_players_fd(player_ids)
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

function M.send_to_client(fd, name, data)
    if not connection[fd] then
        return false
    end
    return M.send_message(fd, name, data)
end

function M.send_to_player(player_id, name, data)
    local fd = player_fd_map[player_id]
    if not fd then
        return false
    end
    return M.send_message(fd, name, data)
end

function M.send_to_players(player_ids, name, data)
    if type(player_ids) ~= "table" then
        return 0
    end
    local count = 0
    for _, player_id in ipairs(player_ids) do
        if M.send_to_player(player_id, name, data) then
            count = count + 1
        end
    end
    return count
end

function M.rpc_response(fd, session, data)
    if not connection[fd] then
        return false
    end
    local pr = pending_responses[fd]
    if not pr then
        return false
    end
    local response_func = pr[session]
    if not response_func then
        return false
    end
    local ok, resp = pcall(response_func, data)
    pr[session] = nil
    if not ok then
        return false
    end
    if not resp then
        return true
    end
    socketdriver.send(fd, string.pack(">s2", resp))
    return true
end

function M.get_online_count()
    local count = 0
    for _ in pairs(player_fd_map) do
        count = count + 1
    end
    return count
end

function M.handler_open(conf)
    local ok, err = M.reload_proto()
    if not ok then
        error("gate init proto failed: " .. tostring(err))
    end
    log.info("Gate service opened")
end

function M.handler_message(fd, msg, sz)
    local c = connection[fd]
    if not c then
        skynet.trash(msg, sz)
        return
    end
    local data = skynet.tostring(msg, sz)
    local ok, msg_type, name, args, response_func, _, session = pcall(host.dispatch, host, data)
    if not ok or not msg_type then
        return
    end
    if msg_type == "REQUEST" then
        if not name then
            M.send_error(fd, 1002, "协议名无效")
            return
        end
        local schema = proto_builder.get_receive_from_client_schema(name)
        if schema and args then
            local valid, err_msg = proto_builder.validate(name, args, schema)
            if not valid then
                M.send_error(fd, 1003, "协议字段验证失败: " .. err_msg)
                return
            end
        end
        if response_func and session then
            local pr = pending_responses[fd]
            if not pr then
                pr = {}
                pending_responses[fd] = pr
            end
            pr[session] = response_func
        end
        if c.agent and c.player_id then
            skynet.redirect(c.agent, fd, "client", fd, skynet.pack(c.player_id, name, args, session))
        else
            local loginS = skynet.localname(".login")
            skynet.redirect(loginS, fd, "client", fd, skynet.pack(name, args, session))
        end
    elseif msg_type == "RESPONSE" then
        log.debug("收到响应: fd=%d, session=%s", fd, tostring(name))
    end
end

function M.handler_connect(fd, addr)
    log.info("client connected, fd=%d, addr=%s", fd, addr)
    connection[fd] = { fd = fd, ip = addr }
end

function M.handler_disconnect(fd)
    local c = connection[fd]
    if c and c.account_key then
        local loginS = skynet.localname(".login")
        skynet.send(loginS, "lua", "disconnect", c.account_key)
        log.info("client disconnected, fd=%d, account_key=%s", fd, c.account_key)
    end
    connection[fd] = nil
end

function M.handler_error(fd, msg)
    M.handler_disconnect(fd)
end

function M.handler_warning(fd, size)
    log.warning(string.format("Client warning: fd=%d, size=%d", fd, size))
end

function M.handler_command(cmd, source, ...)
    local f = M[cmd]
    if f then
        return f(...)
    end
    return false, "Unknown command: " .. cmd
end

return M
