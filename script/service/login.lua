package.path = package.path .. ";./script/?.lua;./script/utils/?.lua"
local skynet = require "skynet"
local user_manager = require "user_manager"
local tableUtils = require "utils.tableUtils"
local account_loading = {}
local account_map = {}
local player_map = {}
local log = require "log"
local CMD = {}

function get_account_info(account)

end 

function CMD.login(fd, account_key)
    log.info(string.format("Login request for account: %s", account_key))
    -- 检查账号是否已经登录
    local agent = account_map[account_key]
    if agent then
        log.info(string.format("Account %s already logged in", account_key))
        return true, agent
    end
    if account_loading[account_key] then
        log.error(string.format("Account %s is already loading", account_key))
        return false
    end
    account_loading[account_key] = true
    -- 请求 dbc 服务查询账号数据
    local dbc = skynet.localname(".dbc")
    local data = skynet.call(dbc, "lua", "query_account", account_key)
    local account_data
    if not next(data) then
        account_data = {
            account_key = account_key,
            players = {},
        }
        local ret = skynet.call(dbc, "lua", "create_account", account_key, {
            account_key = account_key,
            players = tableUtils.serialize_table(account_data.players),
        })
        tableUtils.print_table(ret)
        if not ret then 
            log.error(string.format("Failed to create account %s", account_key))
            account_loading[account_key] = nil
            return false
        end
    else 
        data = data[1]
        account_data = {
            account_key = data.account_key,
            players = tableUtils.deserialize_table(data.players),
        }
    end
    -- 创建新的 agent 服务 
    agent = skynet.newservice("agent")
    skynet.call(agent, "lua", "start", account_key, account_data)
    account_map[account_key] = agent
    account_loading[account_key] = nil
    log.info(string.format("Account %s logged in, agent created: %s", account_key, agent))
    return true, agent
end

function CMD.account_update(account_key, account_data)
    log.info(string.format("Account %s updated", account_key))
    local agent = account_map[account_key]
    local dbc = skynet.localname(".dbc")
    local ret = skynet.call(dbc, "lua", "update_account", account_key, {
        account_key = account_key,
        players = tableUtils.serialize_table(account_data.players),
    })
    tableUtils.print_table(ret)
    if not ret then
        log.error(string.format("Failed to update account %s", account_key))
    end
end

function CMD.player_loaded(account_key, player_id)
    log.info(string.format("Player %s loaded successfully", player_id))
    player_map[account_key] = player_id
end

skynet.start(function()
    skynet.dispatch("lua", function(_, _, command, ...)
        local f = CMD[command]
        if f then
            skynet.ret(skynet.pack(f(...)))
        else
            log.error("Unknown command: " .. command)
        end
    end)
end)