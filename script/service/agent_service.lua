local skynet = require "skynet"
local log = require "log"
local player_obj = require "player_obj"
local CtnBag = require "ctn.ctn_bag"
local CtnCommon = require "ctn.ctn_common"
local common = require "utils.common"
local msg_handle = require "msg_handle"
local event_def = require "define.event_def"
local user_mgr = require "user_mgr"
local tilent_mgr = require "system.tilent.tilent_mgr"
local tableUtils = require "utils.tableUtils"
local protocol_handler = require "protocol_handler"
local service_ctx = require "runtime.service_ctx"

local M = service_ctx.get("agent.agent", {})
M.accounts = M.accounts or {}
M.logout_timers = M.logout_timers or {}
M._protocol_registered = M._protocol_registered or false
M._inited = M._inited or false

local accounts = M.accounts
local logout_timers = M.logout_timers

local function ctn_loaded(player_id, _ctn)
    local player = user_mgr.get_player_obj(player_id)
    if not player or not player.ctn_loading_[_ctn.name_] then
        return
    end
    player.ctn_loading_[_ctn.name_] = nil
    if not next(player.ctn_loading_) then
        M.on_player_loaded(player_id)
    end
end

function M.load_player_data(player)
    player.ctns_ = {
        bag = CtnBag.new(player.player_id_, "bag", "bag"),
        common = CtnCommon.new(player.player_id_, "common", "common"),
    }
    player.ctn_loading_ = {}
    for k, v in pairs(player.ctns_) do
        v:load(function(_ctn)
            ctn_loaded(player.player_id_, _ctn)
        end)
        player.ctn_loading_[k] = true
    end
end

function M.handle_login(player)
    if not player then
        return
    end
    local eventS = skynet.localname(".event")
    skynet.send(eventS, "lua", "trigger", event_def.PLAYER.LOGIN, {
        player_id = player.player_id_,
        player_name = player.player_name_,
        agent = skynet.self(),
    })
end

function M.send_player_data(player)
    protocol_handler.send_to_player(player.player_id_, "player_data", {
        player_id = player.player_id_,
        player_name = player.player_name_,
    })
    tilent_mgr.sync_to_client(player, "login")
end

function M.send_map_entry(player_id)
    local mapS = skynet.localname(".map")
    if not mapS then
        return
    end
    local maps = skynet.call(mapS, "lua", "get_map_list", player_id) or {}
    protocol_handler.send_to_player(player_id, "map_list_notify", {
        maps = maps,
    })
end

function M.sync_map_view(player_id)
    local mapS = skynet.localname(".map")
    if not mapS then
        return
    end
    skynet.send(mapS, "lua", "sync_player_view", player_id)
end

function M.on_player_loaded(player_id)
    local player = user_mgr.get_player_obj(player_id)
    if not player then
        return
    end
    player:on_loaded()
    player.loaded = true
    local account = accounts[player.account_key_]
    if not account then
        return
    end
    local gateS = skynet.localname(".gate")
    skynet.send(gateS, "lua", "register_player", account.args.fd, player_id)
    account.args = nil
    skynet.send(skynet.localname(".login"), "lua", "account_loaded", player.account_key_)
    skynet.send(skynet.localname(".register"), "lua", "register", player_id, skynet.self())
    M.handle_login(player)
    M.send_player_data(player)
    M.send_map_entry(player_id)
    local instanceS = skynet.localname(".instance")
    if instanceS then
        skynet.send(instanceS, "lua", "sync_player_instance_state", player_id)
    end
end

function M.load(account_key)
    local account = accounts[account_key]
    if not account then
        return false
    end
    local _, player_info = next(account.account_data.players)
    local db = skynet.localname(".db")
    local player_data
    if player_info then
        local data = skynet.call(db, "lua", "query_player", player_info.player_id)
        if not data then
            return false
        end
        player_data = {
            account_key = data.account_key,
            player_id = data.player_id,
            player_name = data.player_name,
            info = data.info,
        }
        account.player_id = data.player_id
        log.info("load player, account_key=%s, player_id=%d", account_key, data.player_id)
    else
        local player_id = skynet.call(db, "lua", "gen_id", "player")
        player_data = {
            account_key = account_key,
            player_id = player_id,
            player_name = "Player_" .. math.random(1000, 9999),
            info = {},
        }
        local ret = skynet.call(db, "lua", "create_player", player_id, player_data)
        if not ret then
            return false
        end
        account.player_id = player_id
        account.account_data.players[player_id] = { player_id = player_id, player_name = player_data.player_name }
        skynet.send(skynet.localname(".login"), "lua", "account_update", account_key, account.account_data)
        log.info("create player, account_key=%s, player_id=%d", account_key, player_id)
    end
    if not player_data or account_key ~= player_data.account_key then
        return false
    end
    local player = player_obj.new(player_data.player_id, player_data)
    user_mgr.add_player_obj(player_data.player_id, player)
    M.load_player_data(player)
    return true
end

function M.start(account_key, account_data, args)
    if accounts[account_key] then
        return false
    end
    accounts[account_key] = {
        account_data = account_data,
        player_id = nil,
        loaded = false,
        args = args,
    }
    M.load(account_key)
    return true
end

function M.reconnect(account_key, fd)
    local account = accounts[account_key]
    if not account then
        return false, "Account not found"
    end
    if logout_timers[account_key] then
        logout_timers[account_key]()
        logout_timers[account_key] = nil
    end
    local player = user_mgr.get_player_obj(account.player_id)
    if not player then
        return false, "Player not found"
    end
    log.info("reconnect, fd=%d, account_key=%s, player_id=%d", fd, account_key, account.player_id)
    skynet.send(skynet.localname(".gate"), "lua", "register_player", fd, account.player_id)
    M.handle_login(player)
    if player.loaded_ then
        M.send_player_data(player)
        M.sync_map_view(account.player_id)
    end
    local instanceS = skynet.localname(".instance")
    if instanceS then
        skynet.send(instanceS, "lua", "sync_player_instance_state", account.player_id)
    end
    return true
end

function M.kicked_out(account_key, new_fd)
    local account = accounts[account_key]
    if not account then
        return false, "Account not found"
    end
    if logout_timers[account_key] then
        logout_timers[account_key]()
        logout_timers[account_key] = nil
    end
    skynet.send(skynet.localname(".gate"), "lua", "kick_client", account.player_id, "kicked_out", "您的账号在其他设备登录，已被强制下线")
    local player = user_mgr.get_player_obj(account.player_id)
    if not player then
        return false, "Player not found"
    end
    if player.loaded_ then
        player:save_to_db()
    end
    log.info("kicked_out, new_fd=%d, account_key=%s, player_id=%d", new_fd, account_key, account.player_id)
    skynet.send(skynet.localname(".gate"), "lua", "register_player", new_fd, account.player_id)
    M.send_player_data(player)
    M.sync_map_view(account.player_id)
    return true
end

function M.disconnect(account_key)
    local account = accounts[account_key]
    if not account then
        return false, "Account not found"
    end
    local player = user_mgr.get_player_obj(account.player_id)
    if not player then
        return false, "Player not found"
    end
    log.info("disconnect, account_key=%s, player_id=%d", account_key, account.player_id)
    local matchS = skynet.localname(".match")
    if matchS then
        skynet.send(matchS, "lua", "cancel_match", account.player_id)
    end
    local instanceS = skynet.localname(".instance")
    if instanceS then
        local in_inst, inst_id_or_err = skynet.call(instanceS, "lua", "get_player_instance", account.player_id)
        if in_inst then
            skynet.send(instanceS, "lua", "quit_instance", inst_id_or_err, account.player_id)
        end
    end
    if logout_timers[account_key] then
        logout_timers[account_key]()
        logout_timers[account_key] = nil
    end
    logout_timers[account_key] = common.set_timeout(180 * 100, function()
        if player.loaded_ then
            player:save_to_db()
        end
        local loginS = skynet.localname(".login")
        if loginS then
            skynet.send(loginS, "lua", "account_exit", account_key)
        end
        local mapS = skynet.localname(".map")
        if mapS then
            skynet.send(mapS, "lua", "leave_map", account.player_id)
        end
        accounts[account_key] = nil
        logout_timers[account_key] = nil
        user_mgr.del_player_obj(account.player_id)
        skynet.send(skynet.localname(".register"), "lua", "unregister", account.player_id)
    end)
    return true
end

function M.get_account_count()
    return tableUtils.table_size(accounts)
end

function M.get_managed_accounts()
    local result = {}
    for account_key, account in pairs(accounts) do
        table.insert(result, {
            account_key = account_key,
            player_id = account.player_id,
            loaded = account.loaded,
        })
    end
    return result
end

local function get_player_or_err(player_id)
    local player = user_mgr.get_player_obj(player_id)
    if not player then
        return nil, "Player not found"
    end
    return player
end

function M.get_player_flow(data)
    local player, err = get_player_or_err(data and data.player_id)
    if not player then
        return false, err
    end
    local flow_state, flow_version = player:get_flow_state()
    return true, { flow_state = flow_state, flow_version = flow_version }
end

function M.try_set_player_flow(data)
    local player_id = data and data.player_id
    local expected_states = (data and data.expected_states) or {}
    local new_state = data and data.new_state or "idle"
    local player, err = get_player_or_err(player_id)
    if not player then
        return false, err
    end
    local ok, current = player:try_set_flow_state(expected_states, new_state)
    if not ok then
        return false, string.format("flow state mismatch: current=%s", tostring(current)), current
    end
    return true, new_state
end

function M.shutdown()
    for account_key, account in pairs(accounts) do
        local player = user_mgr.get_player_obj(account.player_id)
        if player and player.loaded_ then
            player:save_to_db()
        end
        if logout_timers[account_key] then
            logout_timers[account_key]()
            logout_timers[account_key] = nil
        end
        local loginS = skynet.localname(".login")
        if loginS then
            skynet.send(loginS, "lua", "agent_exit", account_key)
        end
        local mapS = skynet.localname(".map")
        if mapS then
            skynet.send(mapS, "lua", "leave_map", account.player_id)
        end
    end
    skynet.exit()
end

function M.register_client_protocol()
    if M._protocol_registered then
        return
    end
    M._protocol_registered = true
    skynet.register_protocol({
        name = "client",
        id = skynet.PTYPE_CLIENT,
        unpack = function(msg, sz)
            return skynet.unpack(msg, sz)
        end,
        dispatch = function(fd, _, player_id, name, args, session)
            skynet.ignoreret()
            if msg_handle[name] then
                local ok, result = pcall(msg_handle[name], player_id, args, session)
                if not ok then
                    log.error(string.format("Error handling message %s for player %s: %s", name, player_id, result))
                end
            elseif name ~= "login" then
                log.error(string.format("Unknown message type: %s for player %s", name, player_id))
            end
        end,
    })
end

local function start_timer()
    local interval = 180 * 100
    local function timer_loop()
        skynet.timeout(interval, timer_loop)
        for _, account in pairs(accounts) do
            local player = user_mgr.get_player_obj(account.player_id)
            if player and player.loaded_ then
                player:save_to_db()
            end
        end
    end
    local date = os.date("*t")
    skynet.timeout((60 - date.sec) * 100, timer_loop)
end

function M.init()
    M.register_client_protocol()
    if M._inited then
        return
    end
    M._inited = true
    start_timer()
end

return M
