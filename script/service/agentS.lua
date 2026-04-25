local player_obj = require "player_obj"
local CtnBag = require "ctn.ctn_bag"
local CtnKv = require "ctn.ctn_kv"
local CtnCommon = require "ctn.ctn_common"
local common = require "utils.common"
local msg_handle = require "msg_handle"
local event_def = require "define.event_def"
local user_mgr = require "user_mgr"
local tilent_mgr = require "system.tilent.tilent_mgr"

local agent_id = tonumber(...)
-- 多账号支持
local accounts = {}  -- account_key => {account_data, player_id}
local logout_timers = {} -- account_key => timer_function

-- 定时器函数
local function start_timer()
    local interval = 180 * 100
    local function timer_loop()
        skynet.timeout(interval, timer_loop)
        for account_key, account in pairs(accounts) do
            local player = user_mgr.get_player_obj(account.player_id)
            if player and player.loaded_ then
                player:save_to_db()
            end
        end
    end
    local date = os.date("*t")
    skynet.timeout((60 - date.sec) * 100, timer_loop)
end

function CMD.start(account_key, account_data, args)
    log.debug(string.format("Agent handling account: %s", account_key))
    
    if accounts[account_key] then
        return false
    end
    accounts[account_key] = {
        account_data = account_data,
        player_id = nil,
        loaded = false,
        args = args,
    }
    -- 加载玩家数据
    CMD.load(account_key)
    return true
end

function CMD.load(account_key)
    if not accounts[account_key] then
        log.error(string.format("Account %s not found", account_key))
        return false
    end
    
    local account = accounts[account_key]
    local _, player_info = next(account.account_data.players)
    local db = skynet.localname(".db")
    local player_data
    
    if player_info then 
        local data = skynet.call(db, "lua", "query_player", player_info.player_id)
        if data then
            player_data = {
                account_key = data.account_key,
                player_id = data.player_id,
                player_name = data.player_name,
                info = data.info,
            }
            account.player_id = data.player_id
        else
            log.error(string.format("Failed to load player data for %s", player_info.player_id))
        end
    else
        local db = skynet.localname(".db")
        local player_id = skynet.call(db, "lua", "gen_id", "player")
        player_data = {
            account_key = account_key,
            player_id = player_id,
            player_name = "Player_" .. math.random(1000, 9999),
            info = {},
        }
        local ret = skynet.call(db, "lua", "create_player", player_id, player_data)
        if ret then 
            account.player_id = player_id
            account.account_data.players[player_id] = {
                player_id = player_id,
                player_name = player_data.player_name,
            }
            local login = skynet.localname(".login")
            skynet.send(login, "lua", "account_update", account_key, account.account_data)
        else
            log.error(string.format("Failed to create player data for %s", account_key))
        end 
    end
    
    if not player_data then 
        log.error(string.format("No player data found for %s", account_key))
        return false
    end
    if account_key ~= player_data.account_key then
        log.error(string.format("account_key not match %s %s", account_key, player_info.player_id))
        return false
    end
    
    local player = player_obj.new(account.player_id, player_data)
    user_mgr.add_player_obj(account.player_id, player)
    load_player_data(player)
    return true
end

function load_player_data(player)
    player.ctns_  = {
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

function ctn_loaded(player_id, _ctn)
    local player = user_mgr.get_player_obj(player_id)
    if not player then 
        return 
    end 
    
    if not player.ctn_loading_[_ctn.name_] then 
        return 
    end
    
    player.ctn_loading_[_ctn.name_] = nil
    if not next(player.ctn_loading_) then 
        on_player_loaded(player_id)
    end
end

function on_player_loaded(player_id)
    local player = user_mgr.get_player_obj(player_id)
    if not player then
        return
    end
    
    player:on_loaded()
    player.loaded = true
    local account = accounts[player.account_key_]
    if not account then
        log.error("account not found %s", player.account_key_)
        return
    end
    
    local gateS = skynet.localname(".gate")
    skynet.send(gateS, "lua", "register_player", account.args.fd, player_id)
    account.args = nil

    local loginS = skynet.localname(".login")
    skynet.send(loginS, "lua", "account_loaded", player.account_key_)
    
    local registerS = skynet.localname(".register")
    skynet.send(registerS, "lua", "register", player_id, skynet.self())
    
    -- 触发登录事件
    handle_login(player)
    -- 下发玩家数据
    send_player_data(player)
    -- 恢复副本态快照
    local instanceS = skynet.localname(".instance")
    if instanceS then
        skynet.send(instanceS, "lua", "sync_player_instance_state", player_id)
    end
end

function send_player_data(player)
    protocol_handler.send_to_player(player.player_id_, "player_data", {
            player_id = player.player_id_,
            player_name = player.player_name_,
        }
    )
    tilent_mgr.sync_to_client(player, "login")
end

function handle_login(player)
    if not player then
        return
    end
    
    -- 处理登录逻辑
    local eventS = skynet.localname(".event")
    -- 触发登录事件
    skynet.send(eventS, "lua", "trigger", event_def.PLAYER.LOGIN, {
        player_id = player.player_id_,
        player_name = player.player_name_,
        agent = skynet.self(),
        -- 其他登录相关信息
    })
end

function handle_level_up(player, _new_level)
    if not player then
        return
    end
    
    -- 处理升级逻辑
    local eventS = skynet.localname(".event")
    -- 触发升级事件
    skynet.send(eventS, "lua", "trigger", event_def.PLAYER.LEVEL_UP, {
        player_id = player.player_id_,
        old_level = player.level_,
        new_level = _new_level,
        -- 其他升级相关信息
    })
end

function CMD.reconnect(account_key, fd)
    local account = accounts[account_key]
    if not account then
        return false, "Account not found"
    end

    -- 如果有退出计时器，取消它
    if logout_timers[account_key] then
        logout_timers[account_key]()
        logout_timers[account_key] = nil 
    end
    local player = user_mgr.get_player_obj(account.player_id)
    if not player then
        return false, "Player not found"
    end

    local gateS = skynet.localname(".gate")
    skynet.send(gateS, "lua", "register_player", fd, account.player_id)
    
    -- 触发登录事件
    handle_login(player)

    -- 下发玩家数据
    if player and player.loaded_ then
        send_player_data(player)
    end
    -- 重连后补发副本态快照
    local instanceS = skynet.localname(".instance")
    if instanceS then
        skynet.send(instanceS, "lua", "sync_player_instance_state", account.player_id)
        log.info("agent.sync_instance_state_on_reconnect player=%s", tostring(account.player_id))
    end
    
    log.info(string.format("Player %s reconnected", account.player_id))
    return true
end

-- 处理账号在其他地方登录的顶号逻辑
function CMD.kicked_out(account_key, new_fd)
    local account = accounts[account_key]
    if not account then
        return false, "Account not found"
    end
    
    log.info(string.format("Player %s kicked out due to login elsewhere", account.player_id))
    
    -- 取消可能存在的退出计时器
    if logout_timers[account_key] then
        logout_timers[account_key]()
        logout_timers[account_key] = nil
    end

    local gateS = skynet.localname(".gate")

    skynet.send(gateS, "lua", "kick_client", account.player_id, "kicked_out", "您的账号在其他设备登录，已被强制下线")

    local player = user_mgr.get_player_obj(account.player_id)
    if not player then
        return false, "Player not found"
    end

    -- 如果玩家有需要保存的数据，这里可以保存
    if player and player.loaded_ then
        player:save_to_db()
    end

    local gateS = skynet.localname(".gate")
    skynet.send(gateS, "lua", "register_player", new_fd, account.player_id)

    -- 下发玩家数据
    send_player_data(player)
    
    return true
end

-- 断开连接
function CMD.disconnect(account_key)
    local account = accounts[account_key]
    if not account then
        return false, "Account not found"
    end
    
    log.info(string.format("Player %s disconnected", account.player_id))

    local player = user_mgr.get_player_obj(account.player_id)
    if not player then
        return false, "Player not found"
    end

    -- 离线即清理匹配/副本占用，避免脏状态残留
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
    local old_state = select(1, player:get_flow_state())
    local _, new_state = player:set_flow_state("idle")
    if old_state ~= new_state then
        log.info("agent.player_flow transition player=%s from=%s to=%s reason=disconnect_cleanup request_id=",
            tostring(account.player_id), tostring(old_state), tostring(new_state))
    end

    -- 触发登出事件
    local eventS = skynet.localname(".event")
    if eventS and player then
        skynet.send(eventS, "lua", "trigger", event_def.PLAYER.LOGOUT, {
            player_id = player.player_id_,
        })
    end
    
    -- 设置延迟退出计时器，3分钟后移除账号
    if logout_timers[account_key] then
        logout_timers[account_key]()
        logout_timers[account_key] = nil 
    end
    
    -- 3分钟 = 180秒 = 18000单位（skynet的timeout单位是0.01秒）
    logout_timers[account_key] = common.set_timeout(180 * 100, function()
        log.debug(string.format("Player %s didn't reconnect within 3 minutes, removing from agent", account.player_id))
        
        -- 保存玩家数据
        if player and player.loaded_ then
            player:save_to_db()
        end
        
        -- 通知登录服务，账号已完全登出
        local loginS = skynet.localname(".login")
        if loginS then
            skynet.send(loginS, "lua", "account_exit", account_key)
        end
        -- 从账号表中移除
        accounts[account_key] = nil
        logout_timers[account_key] = nil
        user_mgr.del_player_obj(account.player_id)

        local registerS = skynet.localname(".register")
        skynet.send(registerS, "lua", "unregister", account.player_id)
    end)
    
    log.debug(string.format("Set exit timer for player %s, will be removed in 3 minutes if not reconnected", account.player_id))
    
    return true
end

-- 获取当前agent管理的账号数量
function CMD.get_account_count()
    return tableUtils.table_size(accounts)
end

-- 获取当前agent管理的所有账号
function CMD.get_managed_accounts()
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

function CMD.get_player_flow(data)
    local player_id = data and data.player_id
    local player, err = get_player_or_err(player_id)
    if not player then
        return false, err
    end
    local flow_state, flow_version = player:get_flow_state()
    return true, {
        flow_state = flow_state,
        flow_version = flow_version,
    }
end

function CMD.try_set_player_flow(data)
    local player_id = data and data.player_id
    local expected_states = (data and data.expected_states) or {}
    local new_state = data and data.new_state or "idle"
    local reason = data and data.reason or ""
    local request_id = data and data.request_id or ""
    local player, err = get_player_or_err(player_id)
    if not player then
        return false, err
    end
    local before_state = select(1, player:get_flow_state())
    local ok, current = player:try_set_flow_state(expected_states, new_state)
    if not ok then
        log.warning("agent.player_flow mismatch player=%s from=%s to=%s expected=%s reason=%s request_id=%s",
            tostring(player_id), tostring(before_state), tostring(new_state), tableUtils.serialize_table(expected_states), tostring(reason), tostring(request_id))
        return false, string.format("flow state mismatch: current=%s", tostring(current)), current
    end
    log.info("agent.player_flow transition player=%s from=%s to=%s reason=%s request_id=%s",
        tostring(player_id), tostring(before_state), tostring(new_state), tostring(reason), tostring(request_id))
    return true, new_state
end

-- 在停止服务前确保所有数据都已保存
function CMD.shutdown()
    log.info(string.format("Agent service shutting down, saving %d accounts", tableUtils.table_size(accounts)))
    
    -- 保存所有账号玩家数据
    for account_key, account in pairs(accounts) do
        local player = user_mgr.get_player_obj(account.player_id)
        if player and player.loaded_ then
            player:save_to_db()
        end
        
        -- 取消计时器
        if logout_timers[account_key] then
            logout_timers[account_key]()
            logout_timers[account_key] = nil 
        end
        
        -- 通知登录服务，此账号已完全退出
        local loginS = skynet.localname(".login")
        if loginS then
            skynet.send(loginS, "lua", "agent_exit", account_key)
        end
    end
    
    -- 立即退出服务
    skynet.exit()   
end

skynet.register_protocol {
	name = "client",
	id = skynet.PTYPE_CLIENT,
	unpack = function (msg, sz)
		return skynet.unpack(msg, sz)
	end,
	dispatch = function (fd, _, player_id, name, args, session)
        skynet.ignoreret()
		if msg_handle[name] then
			local ok, result = pcall(msg_handle[name], player_id, args, session)
			if not ok then
				log.error(string.format("Error handling message %s for player %s: %s", name, player_id, result))
			end
        elseif name == "login" then
		else
			log.error(string.format("Unknown message type: %s for player %s", name, player_id))
		end
	end
}

-- 主服务函数
local function main()
    start_timer()
end

-- 使用service_wrapper包装服务
service_wrapper.create_service(main, {
    register_hotfix = false,
    logging_name = "agent." .. agent_id,
})