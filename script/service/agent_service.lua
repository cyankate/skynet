local skynet = require "skynet"
local log = require "log"
local player_obj = require "player_obj"
local CtnBag = require "ctn.ctn_bag"
local CtnCommon = require "ctn.ctn_common"
local CtnDay = require "ctn.ctn_day"
local CtnWeek = require "ctn.ctn_week"
local CtnCondition = require "ctn.ctn_condition"
local CtnTask = require "ctn.ctn_task"
local common = require "utils.common"
local idem = require "utils.idempotent"
local msg_handle = require "net.msg_net"
local event_def = require "define.event_def"
local user_mgr = require "user_mgr"
local talent_mgr = require "system.talent_mgr"
local tableUtils = require "utils.tableUtils"
local protocol_handler = require "protocol_handler"
local item_mgr = require "system.item_mgr"
local trade_mgr = require "system.trade.trade_mgr"
local recovery_mgr = require "system.recovery_mgr"
local weapon_mgr = require "system.weapon_mgr"
local head_mgr = require "system.head_mgr"
local barrier_mgr = require "system.barrier_mgr"
local instance_play_mgr = require "system.instance_play_mgr"
local gm_mgr = require "system.gm_mgr"
local task_mgr = require "system.task.task_mgr"
local effect_mgr = require "system.effect_mgr"
local service_ctx = require "runtime.service_ctx"
local rpc = require "cluster.rpc"
local locator = require "cluster.locator"
local shard = require "map.shard"

local M = service_ctx.get("agent.agent", {})
M.accounts = M.accounts or {}
M.logout_timers = M.logout_timers or {}
M._protocol_registered = M._protocol_registered or false
M._inited = M._inited or false

local accounts = M.accounts
local logout_timers = M.logout_timers

local function apply_gate(account, args)
    args = args or {}
    if not args.gate then
        return
    end
    account.gate = args.gate
end

local function get_gate(account)
    if account and account.gate then
        return account.gate
    end
    log.error("account missing gate, account_key=%s", account and tostring(account.account_key) or "nil")
    return nil
end

local function bind_locator(account, player_id, fd)
    if not account or not fd or not player_id then
        return false
    end
    local gateS = get_gate(account)
    if not gateS then
        return false
    end
    account.cur_fd = fd
    return skynet.call(gateS, "lua", "register_player", fd, player_id)
end

function M.push_client(player_id, name, data)
    local player = user_mgr.get_player_obj(player_id)
    if not player then
        return false
    end
    local account = accounts[player.account_key_]
    local gateS = get_gate(account)
    if not gateS then
        return false
    end
    return skynet.send(gateS, "lua", "send_to_player", player_id, name, data)
end

function M.push_clients(player_ids, name, data)
    if type(player_ids) ~= "table" then
        return 0
    end
    local n = 0
    for _, player_id in ipairs(player_ids) do
        if M.push_client(player_id, name, data) then
            n = n + 1
        end
    end
    return n
end

function M.has_player(player_id)
    return user_mgr.get_player_obj(player_id) ~= nil
end

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
        condition = CtnCondition.new(player.player_id_, "player_condition", "condition"),
        task = CtnTask.new(player.player_id_, "task", "task"),
        day = CtnDay.new(player.player_id_, "player_day", "day"),
        week = CtnWeek.new(player.player_id_, "player_week", "week"),
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
    if not eventS then
        return
    end
    skynet.send(eventS, "lua", "trigger", event_def.PLAYER.LOGIN, {
        player_id = player.player_id_,
        player_name = player.player_name_,
        agent = skynet.self(),
    })
end

--- 连接断开：闪断/顶号旧连接等，数据仍在内存，勿当作正式离线
function M.handle_logout(player)
    if not player then
        return
    end
    local eventS = skynet.localname(".event")
    if not eventS then
        return
    end
    skynet.send(eventS, "lua", "trigger", event_def.PLAYER.LOGOUT, {
        player_id = player.player_id_,
        player_name = player.player_name_,
    })
end

--- 玩家从 agent 卸载前触发（宽限期结束、关服清理等）
function M.handle_offline(player)
    if not player then
        return
    end
    local eventS = skynet.localname(".event")
    if not eventS then
        return
    end
    skynet.send(eventS, "lua", "trigger", event_def.PLAYER.OFFLINE, {
        player_id = player.player_id_,
        player_name = player.player_name_,
    })
end

local function unload_account_from_agent(account_key, account)
    if not account then
        return
    end
    local player_id = account.player_id
    local player = player_id and user_mgr.get_player_obj(player_id)
    if player and player.loaded_ then
        player:save_to_db_sync()
    end
    if player then
        M.handle_offline(player)
    end
    if player and player_id then
        for _, sid in ipairs(shard.all_ids()) do
            local shardS = shard.addr(player.map_id_ or shard.DEFAULT_MAP_ID, sid)
            if shardS then
                skynet.send(shardS, "lua", "leave_map", player_id)
            end
        end
    end
    accounts[account_key] = nil
    logout_timers[account_key] = nil
    if player_id then
        user_mgr.del_player_obj(player_id)
        locator.remove(player_id)
    end
    log.info("unload account from agent, account_key=%s, player_id=%d", account_key, player_id)
end

--- 顶号/rebind 后旧 fd 断开，不应再次走登出逻辑
function M.should_handle_disconnect(account_key, fd)
    local account = accounts[account_key]
    if not account then
        return false
    end
    if account.disconnect_pending then
        return true
    end
    if fd and account.cur_fd and fd ~= account.cur_fd then
        return false
    end
    return true
end

function M.send_player_data(player)
    protocol_handler.send_to_player(player.player_id_, "player_data", {
        player_id = player.player_id_,
        player_name = player.player_name_,
    })
    item_mgr.sync_bag_list_to_client(player)
    talent_mgr.sync_to_client(player)
    weapon_mgr.sync_to_client(player)
    head_mgr.sync_to_client(player)
    barrier_mgr.sync_to_client(player)
    task_mgr.sync_to_client(player)
    effect_mgr.refresh_and_sync(player)
end

--- 玩家已 loaded：跨服 LOGIN + 客户端全量同步 + 副本状态（重连/顶号/首登 load 完成共用）
local function notify_player_online(player)
    if not player or not player.loaded_ then
        return
    end
    M.handle_login(player)
    M.send_player_data(player)
    local instanceS = skynet.localname(".instance")
    if instanceS then
        skynet.send(instanceS, "lua", "sync_player_instance_state", player.player_id_)
    end
end

function M.is_account_ready(account_key)
    local account = accounts[account_key]
    return account ~= nil and account.loaded == true
end

function M.on_player_loaded(player_id)
    local player = user_mgr.get_player_obj(player_id)
    if not player then
        return
    end
    if player.is_new_ then
        player:init_new_player()
        player.is_new_ = false
        player:save_to_db()
    end
    player:on_loaded()
    local account = accounts[player.account_key_]
    if not account then
        return
    end
    account.loaded = true
    account.args = nil
    if account.cur_fd then
        bind_locator(account, player_id, account.cur_fd)
    end
    local loginS = skynet.localname(".login")
    if loginS then
        local ok, result, err = rpc.call_timeout(loginS, 100, "account_loaded", player.account_key_)
        if not ok or not result then
            log.error("account_loaded notify failed, account=%s err=%s",
                tostring(player.account_key_), tostring(err))
        end
    end
    -- 补发离线期间支付的奖励（幂等；失败下次登录再试）
    -- 必须放在 locator.set_agent 之后，paymentS 才能通过 locator 找到本 agent
    locator.set_agent(player_id, skynet.self())
    local paymentS = rpc.named_addr(".payment")
    if paymentS then
        skynet.send(paymentS, "lua", "claim_player_rewards", player_id)
    end
    notify_player_online(player)
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
            is_new = true,
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
    local player = player_obj.new(player_data.player_id, player_data)
    user_mgr.add_player_obj(player_data.player_id, player)
    M.load_player_data(player)
    return true
end

local function start_inner(account_key, account_data, args)
    if accounts[account_key] then
        return false, "account already exists"
    end
    accounts[account_key] = {
        account_data = account_data,
        player_id = nil,
        loaded = false,
        cur_fd = args and args.fd,
        args = args,
    }
    apply_gate(accounts[account_key], args)
    if not M.load(account_key) then
        accounts[account_key] = nil
        return false, "load player failed"
    end
    return true
end

-- req_id 由登录服生成：同一请求因超时重试时，agent 侧只执行一次
function M.start(account_key, account_data, args, req_id)
    if not req_id then
        return start_inner(account_key, account_data, args)
    end
    return idem.run(req_id, function()
        return start_inner(account_key, account_data, args)
    end)
end

function M.reconnect(account_key, fd, gate_args)
    local account = accounts[account_key]
    if not account then
        return false, "Account not found"
    end
    apply_gate(account, gate_args)
    if logout_timers[account_key] then
        logout_timers[account_key]()
        logout_timers[account_key] = nil
    end
    local player = user_mgr.get_player_obj(account.player_id)
    if not player then
        return false, "Player not found"
    end
    log.info("reconnect, fd=%d, account_key=%s, player_id=%d", fd, account_key, account.player_id)
    account.disconnect_pending = false
    bind_locator(account, account.player_id, fd)
    notify_player_online(player)
    return true
end

function M.kicked_out(account_key, new_fd, gate_args)
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
    locator.kick(account.player_id, "kicked_out", "您的账号在其他设备登录，已被强制下线")
    apply_gate(account, gate_args)
    if player.loaded_ then
        player:save_to_db()
    end
    log.info("kicked_out, new_fd=%d, account_key=%s, player_id=%d", new_fd, account_key, account.player_id)
    account.disconnect_pending = false
    bind_locator(account, account.player_id, new_fd)
    notify_player_online(player)
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
    if account.disconnect_pending then
        return true
    end
    account.disconnect_pending = true

    log.info("disconnect, account_key=%s, player_id=%d", account_key, account.player_id)
    M.handle_logout(player)

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
    barrier_mgr.clear_session(player)
    if logout_timers[account_key] then
        logout_timers[account_key]()
        logout_timers[account_key] = nil
    end
    logout_timers[account_key] = common.set_timeout(180 * 100, function()
        local loginS = skynet.localname(".login")
        if loginS then
            skynet.send(loginS, "lua", "account_exit", account_key)
        end
        unload_account_from_agent(account_key, account)
    end)
    return true
end

function M.get_account_count()
    return tableUtils.table_size(accounts)
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

function M.instance_play_settle(data)
    local player, err = get_player_or_err(data and data.player_id)
    if not player then
        return false, err
    end
    return instance_play_mgr.on_complete(player, data)
end

function M.instance_play_action(data)
    local player, err = get_player_or_err(data and data.player_id)
    if not player then
        return false, err
    end
    return instance_play_mgr.on_action(player, data)
end

function M.remember_march(data)
    data = data or {}
    local player = user_mgr.get_player_obj(data.player_id)
    if not player then
        return false, "Player not found"
    end
    player.march_shards_ = player.march_shards_ or {}
    local uid = tostring(data.march_uid or "")
    if uid == "" then
        return true
    end
    if data.removed then
        player.march_shards_[uid] = nil
    elseif data.shard_id ~= nil then
        player.march_shards_[uid] = data.shard_id
    end
    return true
end

function M.add_items(data)
    data = data or {}
    local player, err = get_player_or_err(data.player_id)
    if not player then
        return false, err
    end
    if type(data.items) ~= "table" then
        return false, "invalid items"
    end
    return item_mgr.add_items(player, data.items, data.reason or "map_gather")
end

-- 关键发奖：items 和 op_log 在同一个 DB 事务里；同一 op_id 只生效一次
function M.grant_items_critical(data)
    data = data or {}
    if not data.op_id then
        return false, "missing op_id"
    end
    local player = user_mgr.get_player_obj(data.player_id)
    if not player then
        return false, "Player not found"
    end
    if type(data.items) ~= "table" then
        return false, "invalid items"
    end
    return player:grant_items_critical(data.op_id, data.items, data.reason or "critical_grant")
end

-- 交易行（GM / 调试入口；正常走 C2S net.trade_net）
function M.trade_list(data)
    data = data or {}
    local player = user_mgr.get_player_obj(data.player_id)
    if not player then
        return false, "Player not found"
    end
    return trade_mgr.list(player, data.item_id, data.count, data.price, data.currency_item_id)
end

function M.trade_buy(data)
    data = data or {}
    local player = user_mgr.get_player_obj(data.player_id)
    if not player then
        return false, "Player not found"
    end
    return trade_mgr.buy(player, data.order_id)
end

function M.trade_cancel(data)
    data = data or {}
    local player = user_mgr.get_player_obj(data.player_id)
    if not player then
        return false, "Player not found"
    end
    return trade_mgr.cancel(player, data.order_id)
end

function M.trade_query(data)
    data = data or {}
    return trade_mgr.query(data.page, data.page_size)
end

function M.gm_command(data)
    data = data or {}
    local player, err = get_player_or_err(data.player_id)
    if not player then
        return false, err or "Player not found"
    end
    return gm_mgr.execute(player, data.action, data.args or data)
end

function M.shutdown()
    for account_key, account in pairs(accounts) do
        if logout_timers[account_key] then
            logout_timers[account_key]()
            logout_timers[account_key] = nil
        end
        local loginS = skynet.localname(".login")
        if loginS then
            skynet.send(loginS, "lua", "agent_exit", account_key)
        end
        unload_account_from_agent(account_key, account)
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

function M.on_event(event_name, reset_day_key, ts)
    if event_name == event_def.TIMER.DAY_RESET then
        for _, account in pairs(accounts) do
            local player = user_mgr.get_player_obj(account.player_id)
            if player and player.loaded_ then
                recovery_mgr.check_and_reset(player)
            end
        end
    end
end

function M.list_accounts()
    local t = {}
    for account_key, acc in pairs(accounts) do
        if acc.player_id then
            t[#t + 1] = {
                account_key = account_key,
                player_id = acc.player_id,
                logout = acc.disconnect_pending == true,
            }
        end
    end
    return t
end

function M.init()
    M.register_client_protocol()
    protocol_handler.set_local_agent(M)
    if M._inited then
        return
    end
    M._inited = true

    local bind = package.loaded["agent.worker_bind"]
    local agent_id = bind and tonumber(bind.agent_id)
    if agent_id then
        skynet.name(".agent." .. agent_id, skynet.self())
        -- 延迟到 init 返回之后：supervisor 重启本服务时正阻塞在 newservice，不能同步回 call
        skynet.timeout(0, function()
            local sup = skynet.localname(".supervisor")
            if not sup then
                return
            end
            pcall(skynet.call, sup, "lua", "watch", skynet.self(), {
                entry = "agentS",
                args = { agent_id },
                kind = "agent",
                agent_id = agent_id,
                on_down = { name = ".login", method = "agent_down" },
                on_up = { name = ".login", method = "agent_up", args = { agent_id } },
            })
        end)
    end

    local eventS = skynet.localname(".event")
    if eventS then
        skynet.call(eventS, "lua", "subscribe", event_def.TIMER.DAY_RESET, skynet.self())
    end

    local function idem_tick()
        skynet.timeout(6000, idem_tick)
        idem.prune()
    end
    skynet.timeout(6000, idem_tick)

    start_timer()
end

return M
