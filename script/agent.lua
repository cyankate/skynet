package.path = package.path .. ";./script/?.lua;./script/utils/?.lua"
local skynet = require "skynet"
local tableUtils = require "utils.tableUtils"
require "skynet.manager"
local player_obj = require "player_obj"
local ctn_bag = require "ctn.ctn_bag"
local ctn_kv = require "ctn.ctn_kv"
local log = require "log"
local msg_handle = require "msg_handle"

local CMD = {}
local account_key
local account_data
local player_id

-- 定时器函数
local function start_timer()
    local interval = 1 * 60 * 100 -- 3 分钟，单位是 0.01 秒
    local function timer_loop()
        skynet.timeout(interval, timer_loop) -- 设置下一次定时器
        if player and player.loaded_ then
            log.debug(string.format("Timer triggered for player %s", player.player_id_))
            -- 在这里添加需要轮询的逻辑
            -- 例如：保存玩家数据、检查状态等
            player:save_to_db()
        end
    end
    local date = os.date("*t")
    skynet.timeout((60 - date.sec) * 100, timer_loop) -- 启动定时器
end

function CMD.start(_account_key, _data)
    log.info(string.format("Agent %s started", _account_key, account_data))
    account_key = _account_key
    account_data = _data
    CMD.load()
    start_timer()
end

function CMD.load()
    local _, player_info = next(account_data.players)
    local dbc = skynet.localname(".dbc")
    local player_data
    if player_info then 
        local data = skynet.call(dbc, "lua", "query_player", player_info.player_id)
        if next(data) then
            data = data[1]
            player_data = {
                account_key = data.account_key,
                player_id = data.player_id,
                player_name = data.player_name,
                info = tableUtils.deserialize_table(data.info),
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
        local ret = skynet.call(dbc, "lua", "create_player", account_key, {
            account_key = account_key,
            player_name = player_data.player_name,
            info = tableUtils.serialize_table(player_data.info),
        })
        if ret then 
            player_id = ret.insert_id
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

function ctn_loaded(ctn)
    if not player then 
        return 
    end 
    if not player.ctn_loading_[ctn.name_] then 
        return 
    end
    log.info(string.format("Container %s loaded", ctn))
    player.ctn_loading_[ctn.name_] = nil
    if not next(player.ctn_loading_) then 
        log.info(string.format("All containers loaded for player %s", player.player_id_))
        player:loaded()
    end
    local login = skynet.localname(".login")
    skynet.send(login, "lua", "player_loaded", account_key, player.player_id_)
end

function CMD.disconnect()
    log.info(string.format("Agent %s disconnecting", fd))
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
		skynet.trace()
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