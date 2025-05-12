package.path = package.path .. ";./script/?.lua;./script/utils/?.lua"
local skynet = require "skynet"
local tableUtils = require "utils.tableUtils"
require "skynet.manager"
local player_obj = require "player_obj"
local ctn_bag = require "ctn.ctn_bag"
local ctn_kv = require "ctn.ctn_kv"
local log = require "log"
local common = require "utils.common"
local msg_handle = require "msg_handle"
local event_def = require "define.event_def"  -- 添加事件定义

local CMD = {}
local account_key
local account_data
local client_fd
local player_id
local player

-- 添加退出计时器变量
local logout_timer = nil

-- 定时器函数
local function start_timer()
    local interval = 1 * 180 * 100 -- 3 分钟，单位是 0.01 秒
    local function timer_loop()
        skynet.timeout(interval, timer_loop) -- 设置下一次定时器
        if player and player.loaded_ then
            local ctn = player:get_ctn("bag")
            ctn:add_item({item_id = math.random(1, 9), count = 5})
            -- 在这里添加需要轮询的逻辑
            -- 例如：保存玩家数据、检查状态等
            player:save_to_db()
        end
    end
    local date = os.date("*t")
    skynet.timeout((60 - date.sec) * 100, timer_loop) -- 启动定时器
end

function CMD.start(_account_key, _data, _fd)
    log.info(string.format("Agent %s started", _account_key))
    account_key = _account_key
    account_data = _data
    client_fd = _fd
    CMD.load()
    return true
end

function CMD.load()
    local _, player_info = next(account_data.players)
    local db = skynet.localname(".db")
    local player_data
    if player_info then 
        local data = skynet.call(db, "lua", "query_player", player_info.player_id)
        if next(data) then
            data = data[1]
            player_data = {
                account_key = data.account_key,
                player_id = data.player_id,
                player_name = data.player_name,
                info = data.info,
            }
            player_id = data.player_id
            log.info(string.format("Player %s loaded", player_id))
            -- 这里可以添加更多的逻辑来处理玩家数据
        else
            log.error(string.format("Failed to load player data for %s", player_info.player_id))
        end
    else
        player_data = {
            account_key = account_key,
            player_name = "Player_" .. math.random(1000, 9999),
            info = {},
        }
        local ret = skynet.call(db, "lua", "create_player", account_key, {
            account_key = account_key,
            player_name = player_data.player_name,
            info = player_data.info,
        })
        if ret then 
            local db = skynet.localname(".db")
            player_id = skynet.call(db, "lua", "gen_id", "player")
            log.info(string.format("Player %s created", player_id))
            -- 这里可以添加更多的逻辑来处理新创建的玩家数据
            account_data.players[player_id] = {
                player_id = player_id,
                player_name = player_data.player_name,
            }
            local login = skynet.localname(".login")
            skynet.send(login, "lua", "account_update", account_key, account_data)
        else
            log.error(string.format("Failed to create player data for %s", account_key))
        end 
    end
    if not player_data then 
        log.error(string.format("No player data found for %s", account_key))
        return
    end
    player = player_obj.new(player_id, player_data)
    load_player_data()
end

function load_player_data()
    player.ctns_  = {
        -- 这里可以添加更多的容器对象
        -- 例如：背包、仓库等
        bag = ctn_bag.new(player.player_id_, "bag", "bag"),
        base = ctn_kv.new(player.player_id_, "base", "base"),
        -- 这里可以添加更多的容器对象

    }
    
    for k, v in pairs(player.ctns_) do
        v:load(ctn_loaded)
        player.ctn_loading_[k] = true
    end
end

function ctn_loaded(_ctn)
    if not player then 
        return 
    end 
    if not player.ctn_loading_[_ctn.name_] then 
        return 
    end
    --log.info(string.format("Container %s loaded", _ctn))
    player.ctn_loading_[_ctn.name_] = nil
    if not next(player.ctn_loading_) then 
        log.info(string.format("All containers loaded for player %s", player.player_id_))
        on_player_loaded()
    end
end

function on_player_loaded()
    player:loaded()
    start_timer()
    -- 触发登录事件
    handle_login(player_id)
    -- 下发玩家数据
    send_player_data()
end 

function send_player_data()
    local gate = skynet.localname(".gate")
    skynet.send(gate, "lua", "send_message", client_fd, {
        name = "player_data",
        data = {
            player_id = player.player_id_,
            player_name = player.player_name_,
        }
    })
end 

function handle_login(_player_id)
    -- 处理登录逻辑
    local eventS = skynet.localname(".event")
    -- 触发登录事件
    skynet.call(eventS, "lua", "trigger", event_def.PLAYER.LOGIN, {
        player_id = _player_id,
        level = player.level,
        agent = skynet.self(),
        -- 其他登录相关信息
    })
end 

function handle_level_up(_player_id, _new_level)
    -- 处理升级逻辑
    
    local eventS = skynet.localname(".event")
    -- 触发升级事件
    skynet.call(eventS, "lua", "trigger", event_def.PLAYER.LEVEL_UP, {
        player_id = _player_id,
        old_level = player.level,
        new_level = _new_level,
        -- 其他升级相关信息
    })
end

-- 处理聊天消息
function CMD.chat_message(msg)
    -- 将消息转发给客户端
    local response = {
        name = "chat_message",
        data = msg
    }
    
    local gate = skynet.localname(".gate")
    if gate then
        skynet.send(gate, "lua", "send_message", client_fd, response)
    else
        log.error("Gate service not found")
    end
    
    log.debug(string.format("Chat message forwarded to player %d: %s", player_id, msg.content))
end

-- 处理发送频道消息请求
function CMD.send_channel_message(channel_id, message)
    if not player or not player.loaded_ then
        return false, "Player not loaded"
    end
    log.debug(string.format("send_channel_message %s %s", channel_id, message))
    local chatS = skynet.localname(".chat")
    if not chatS then
        return false, "Chat service not available"
    end
    
    return skynet.call(chatS, "lua", "send_channel_msg", channel_id, player_id, message)
end

-- 处理发送私聊消息请求
function CMD.send_private_message(to_player_id, message)
    if not player or not player.loaded_ then
        return false, "Player not loaded"
    end
    
    local chatS = skynet.localname(".chat")
    if not chatS then
        return false, "Chat service not available"
    end
    
    return skynet.call(chatS, "lua", "send_private_msg", player_id, to_player_id, message)
end

-- 处理获取频道列表请求
function CMD.get_channel_list()
    local chatS = skynet.localname(".chat")
    if not chatS then
        return nil, "Chat service not available"
    end
    
    return skynet.call(chatS, "lua", "get_channel_list")
end

-- 处理加入频道请求
function CMD.join_channel(channel_id)
    if not player or not player.loaded_ then
        return false, "Player not loaded"
    end
    
    local chatS = skynet.localname(".chat")
    if not chatS then
        return false, "Chat service not available"
    end
    
    return skynet.call(chatS, "lua", "join_channel", channel_id, player_id, player.player_name_)
end

-- 处理离开频道请求
function CMD.leave_channel(channel_id)
    if not player or not player.loaded_ then
        return false, "Player not loaded"
    end
    
    local chatS = skynet.localname(".chat")
    if not chatS then
        return false, "Chat service not available"
    end
    
    return skynet.call(chatS, "lua", "leave_channel", channel_id, player_id)
end

-- 处理获取频道历史消息请求
function CMD.get_channel_history(channel_id, count)
    local chatS = skynet.localname(".chat")
    if not chatS then
        return nil, "Chat service not available"
    end
    
    return skynet.call(chatS, "lua", "get_channel_history", channel_id, count)
end

-- 处理获取私聊历史消息请求
function CMD.get_private_history(other_player_id, count)
    if not player or not player.loaded_ then
        return nil, "Player not loaded"
    end
    
    local chatS = skynet.localname(".chat")
    if not chatS then
        return nil, "Chat service not available"
    end
    
    return skynet.call(chatS, "lua", "get_private_history", player_id, other_player_id, count)
end

-- 添加一个玩家重新上线的函数
function CMD.reconnect(fd)
    -- 如果有退出计时器，取消它
    if logout_timer then
        logout_timer()
        logout_timer = nil 
        log.info(string.format("Player %s reconnected, cancel exit timer", player_id))
    end
    
    -- 更新客户端连接标识
    client_fd = fd
    -- 下发玩家数据
    send_player_data()
    log.info(string.format("Player %s reconnected, new fd: %s", player_id, fd))
end

-- 处理账号在其他地方登录的顶号逻辑
function CMD.kicked_out(new_fd)
    log.info(string.format("Player %s kicked out due to login elsewhere", player_id))
    
    -- 记录旧的客户端fd
    local old_fd = client_fd
    
    -- 更新为新的客户端连接
    client_fd = new_fd
    
    -- 取消可能存在的退出计时器
    if logout_timer then
        logout_timer()
        logout_timer = nil
    end

    local gate = skynet.localname(".gate")
    skynet.send(gate, "lua", "send_message", old_fd, {
        name = "kicked_out",
        data = {
            reason = "kicked_out",
            message = "您的账号在其他设备登录，已被强制下线"
        }
    })
    
    -- 如果玩家有需要保存的数据，这里可以保存
    if player and player.loaded_ then
        player:save_to_db()
    end

    -- 下发玩家数据
    send_player_data()
    
    log.info(string.format("Player %s connection switched from fd %s to fd %s", player_id, old_fd, new_fd))
    
    return true
end

-- 修改断开连接的处理逻辑
function CMD.disconnect()
    log.info(string.format("Player %s disconnected", player_id))
    
    -- 触发登出事件
    local eventS = skynet.localname(".event")
    if eventS and player then
        skynet.call(eventS, "lua", "trigger", event_def.PLAYER.LOGOUT, {
            player_id = player_id
        })
    end
    
    -- 通知登录服务玩家已登出（但agent服务仍在运行）
    local loginS = skynet.localname(".login")
    if loginS then
        skynet.call(loginS, "lua", "logout", account_key)
    end
    
    -- 清除客户端连接标识
    client_fd = nil
    
    -- 设置延迟退出计时器，3分钟后退出服务
    if logout_timer then
        logout_timer()
        logout_timer = nil 
    end
    
    -- 3分钟 = 180秒 = 18000单位（skynet的timeout单位是0.01秒）
    logout_timer = common.set_timeout(18000, function()
        log.info(string.format("Player %s didn't reconnect within 3 minutes, exiting agent service", player_id))
        
        -- 保存玩家数据
        if player and player.loaded_ then
            player:save_to_db()
        end
        
        -- 通知登录服务，此agent服务已完全退出
        local loginS = skynet.localname(".login")
        if loginS then
            skynet.call(loginS, "lua", "agent_exit", account_key)
        end
        
        -- 退出服务
        skynet.exit()
    end)
    
    log.info(string.format("Set exit timer for player %s, will exit in 3 minutes if not reconnected", player_id))
    
    return true
end

-- 在停止服务前确保所有数据都已保存
function CMD.shutdown()
    log.info(string.format("Agent service for player %s shutting down", player_id))
    
    -- 保存玩家数据
    if player and player.loaded_ then
        player:save_to_db()
    end
    
    -- 取消计时器
    if logout_timer then
        logout_timer()
        logout_timer = nil 
    end
    
    -- 通知登录服务，此agent服务已完全退出
    local loginS = skynet.localname(".login")
    if loginS then
        skynet.call(loginS, "lua", "agent_exit", account_key)
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
	dispatch = function (_, _, name, args)
		skynet.ignoreret()	-- session is fd, don't call skynet.ret
        if msg_handle[name] then
            local ok, result = pcall(msg_handle[name], args)
            if not ok then
                log.error(string.format("Error handling message %s: %s", name, result))
            end
        else
            log.error(string.format("Unknown message type: %s", name))
        end
	end
}

skynet.start(function()
    log.info("new agent")

    skynet.dispatch("lua", function(_, _, cmd, ...)
        local f = CMD[cmd]
        if f then
            skynet.ret(skynet.pack(f(...)))
        else
            log.error("Unknown command: " .. tostring(cmd))
        end
    end)
end)