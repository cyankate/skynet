package.path = package.path .. ";./script/?.lua;./script/utils/?.lua"
local skynet = require "skynet"
local user_manager = require "user_manager"
local tableUtils = require "utils.tableUtils"
local account_loading = {}
local account_info = {}
local player_map = {}
local log = require "log"
local CMD = {}

function get_account_info(account)

end 

function CMD.login(fd, account_key)
    log.info(string.format("Login request for account: %s", account_key))
    -- 检查账号是否已经登录
    local ainfo = account_info[account_key]
    if ainfo and ainfo.agent then
        log.info(string.format("Account %s already logged in, handling relogin", account_key))
        
        ainfo.fd = fd
        -- 向agent服务发送顶号通知
        skynet.send(ainfo.agent, "lua", "kicked_out", ainfo.fd)

        log.info(string.format("Account %s kicked out from fd %s", account_key, ainfo.fd))
        
        return true, ainfo.agent
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
    agent = skynet.newservice("agentS")
    skynet.call(agent, "lua", "start", account_key, account_data, fd)
    account_info[account_key] = {agent = agent, fd = fd}
    account_loading[account_key] = nil
    log.info(string.format("Account %s logged in, agent created: %s", account_key, agent))
    return true, agent
end

function CMD.account_update(account_key, account_data)
    log.info(string.format("Account %s updated", account_key))
    local dbc = skynet.localname(".dbc")
    local ret = skynet.call(dbc, "lua", "update_account", account_key, {
        account_key = account_key,
        players = tableUtils.serialize_table(account_data.players),
    })
    if not ret then
        log.error(string.format("Failed to update account %s", account_key))
    end
end

function CMD.player_join_loginS(account_key, player_id)
    player_map[account_key] = player_id
    log.info(string.format("Player %s joined loginS", player_id))
end

-- 添加查找账号信息的功能
function CMD.find_account(account_key)
    log.info(string.format("Finding account info for: %s", account_key))
    
    -- 检查账号是否已有agent服务
    local ainfo = account_info[account_key]
    if ainfo and ainfo.agent then
        -- 返回账号信息，包含agent服务引用
        return {
            account_key = account_key,
            agent = ainfo.agent,
            logout = ainfo.logout
        }
    end
    
    return nil
end

-- 处理账号登出
function CMD.logout(account_key)
    log.info(string.format("Account %s logged out", account_key))
    
    -- 注意：我们不立即移除account_map中的映射，
    -- 这样玩家在3分钟内重连时仍能找到原来的agent
    -- 实际清理会在agent服务彻底退出时进行
    if not account_info[account_key] then
        log.error(string.format("Account %s not found", account_key))
        return false
    end
    account_info[account_key].logout = true 
    return true
end

-- 当agent服务彻底退出时调用此函数
function CMD.agent_exit(account_key)
    log.info(string.format("Agent for account %s exited completely", account_key))
    
    -- 清理账号映射
    account_info[account_key] = nil
    
    return true
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