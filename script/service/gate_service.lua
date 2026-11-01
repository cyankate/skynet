local skynet = require "skynet"
local socketdriver = require "skynet.socketdriver"
local sprotoloader = require "sprotoloader"
local tableUtils = require "utils.tableUtils"
local log = require "log"
local proto_builder = require "utils.proto_builder"
local service_ctx = require "runtime.service_ctx"
local rpc = require "cluster.rpc"
local locator = require "cluster.locator"
local layout = require "cluster.layout"
local gate_routes = require "cluster.gate_routes"

local M = service_ctx.get("gate.gate", {})
M.connection = M.connection or {}
M.player_fd_map = M.player_fd_map or {}
M.pending_responses = M.pending_responses or {}
M.message_count = M.message_count or {}
M.gate_id = M.gate_id or 1
M.gate_name = M.gate_name or ".gate.1"
M.gate_node = M.gate_node or layout.self_node()

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

function M.init_identity(gate_id)
    M.gate_id = tonumber(gate_id) or 1
    M.gate_name = layout.gate_name(M.gate_id)
    M.gate_node = layout.self_node()
end

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

function M.register_player(fd, player_id)
    if not fd or not player_id then
        return false
    end
    local c = connection[fd]
    if not c then
        return false
    end
    local old_fd = player_fd_map[player_id]
    if old_fd and old_fd ~= fd then
        local old_c = connection[old_fd]
        if old_c then
            old_c.player_id = nil
        end
    end
    c.player_id = player_id
    player_fd_map[player_id] = fd
    locator.bind(player_id, M.gate_name, M.gate_node)
    return true
end

--- 按 player_id 踢下线并解除 gate 上的玩家绑定（顶号用）
function M.kick_player(player_id, reason, message)
    local old_fd = player_fd_map[player_id]
    if not old_fd then
        return false
    end
    player_fd_map[player_id] = nil
    local c = connection[old_fd]
    if c then
        c.player_id = nil
    end
    return M.kick_client(old_fd, reason, message)
end

-- 按账号踢连接：agent 崩溃后让玩家重新登录
function M.kick_account(account_key, reason, message)
    if not account_key then
        return false
    end
    for fd, c in pairs(connection) do
        if c.account_key == account_key then
            return M.kick_client(fd, reason, message)
        end
    end
    return false
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

-- locator 重启重建玩家目录用：当前连接上的 player → gate/agent 快照
function M.list_players()
    local t = {}
    for player_id, fd in pairs(player_fd_map) do
        local c = connection[fd]
        if c then
            t[#t + 1] = {
                player_id = player_id,
                agent = c.agent,
                account_key = c.account_key,
            }
        end
    end
    return t
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

function M.handler_open(conf)
    local ok, err = M.reload_proto()
    if not ok then
        error("gate init proto failed: " .. tostring(err))
    end
    log.info("Gate service opened, name=%s node=%s", M.gate_name, M.gate_node)
end

local function direct_target(player_id, name)
    local target = gate_routes[name]
    if type(target) == "function" then
        local ok, v = pcall(target, player_id)
        return ok and v or nil
    end
    return target
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
        local direct = c.player_id and direct_target(c.player_id, name)
        if direct then
            local target = rpc.named_addr(direct)
            if target then
                skynet.redirect(target, fd, "client", fd, skynet.pack(c.player_id, name, args, session))
                return
            end
        end
        if c.agent and c.player_id then
            skynet.redirect(c.agent, fd, "client", fd, skynet.pack(c.player_id, name, args, session))
        else
            local loginS = rpc.named_addr(".login")
            if loginS then
                skynet.redirect(loginS, skynet.self(), "client", fd,
                    skynet.pack(name, args, session, M.gate_name, M.gate_node))
            end
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
    if c then
        if c.player_id and player_fd_map[c.player_id] == fd then
            player_fd_map[c.player_id] = nil
            locator.unbind(c.player_id, M.gate_name, M.gate_node)
        end
        if c.account_key then
            local loginS = rpc.named_addr(".login")
            if loginS then
                skynet.send(loginS, "lua", "disconnect", c.account_key, fd)
            end
            log.info("client disconnected, fd=%d, account_key=%s", fd, c.account_key)
        end
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
