package.path = package.path .. ";./script/?.lua;./script/utils/?.lua"
local skynet = require "skynet"
local mysql = require "skynet.db.mysql"
local sprotoloader = require "sprotoloader"
local tableUtils = require "utils.tableUtils"
local log = require "log"
require "skynet.manager"

local pool = {}
local POOL_SIZE = 10
local CMD = {}

local DB_CONNECTION = {
    host = "127.0.0.1",
    port = 3306,
    database = "skynet",
    user = "root",
    password = "1234",
    max_packet_size = 1024 * 1024,
}

function connect()
    for i = 1, POOL_SIZE do 
        local db = mysql.connect(DB_CONNECTION)

        if not db then
            log.error("[error] Failed to connect to MySQL")
            return nil
        end
        table.insert(pool, db)
    end 
    log.info(" Connected to MySQL")
end     

function CMD.select(_tbl, _cond, _options)
    local lba = _options and _options.lba or 0
    local db = get_connection(lba)
    if not db then
        log.error("[error] No available database connections")
        return nil
    end
    local cond_list = {}
    for k, v in pairs(_cond) do
        table.insert(cond_list, string.format("%s=%s", k, mysql.quote_sql_str(tostring(v))))
    end
    local cond_str = table.concat(cond_list, " AND ")
    local sql = string.format("SELECT * FROM %s WHERE %s", _tbl, cond_str)
    if _options and _options.limit then
        sql = sql .. string.format(" LIMIT %d", _options.limit)
    end

    log.debug("SQL Query: %s", sql)
    local result, err = db:query(sql)
    release(db)

    if not result then
        log.error("[error] MySQL query failed: ", sql, err)
        return nil
    end

    return result
end

function CMD.insert(_tbl, _data, _options)
    local lba = _options and _options.lba or 0
    local db = get_connection(lba)
    if not db then
        log.error("[error] No available database connections")
        return nil
    end
    local fields = {}
    local values = {}
    for k, v in pairs(_data) do
        table.insert(fields, k)
        table.insert(values, mysql.quote_sql_str(tostring(v)))
    end
    local fields_str = table.concat(fields, ",")
    local values_str = table.concat(values, ",")

    local sql = string.format("INSERT INTO %s (%s) VALUES (%s)", _tbl, fields_str, values_str)

    local result, err = db:query(sql)
    release(db)

    if not result then
        log.error("[error] MySQL query failed: ", sql, err)
        return nil
    end

    return result
end

function CMD.update(_tbl, _cond, _data, _options)
    local lba = _options and _options.lba or 0
    local db = get_connection(lba)
    if not db then
        log.error("[error] No available database connections")
        return nil
    end
    local set_list = {}
    print(_tbl, _data)
    for k, v in pairs(_data) do
        table.insert(set_list, string.format("%s=%s", k, mysql.quote_sql_str(tostring(v))))
    end
    local set_str = table.concat(set_list, ",")
    local cond_list = {}
    for k, v in pairs(_cond) do
        table.insert(cond_list, string.format("%s=%s", k, mysql.quote_sql_str(tostring(v))))
    end
    local cond_str = table.concat(cond_list, " AND ")
    local sql = string.format("UPDATE %s SET %s WHERE %s", _tbl, set_str, cond_str)

    local result, err = db:query(sql)
    release(db)

    if not result then
        log.error("[error] MySQL query failed: ", sql, err)
        return nil
    end

    return result
end

function CMD.delete(_tbl, _cond, _options)
    local lba = _options and _options.lba or 0
    local db = get_connection(lba)
    if not db then
        log.error("[error] No available database connections")
        return nil
    end
    local cond_list = {}
    for k, v in pairs(_cond) do
        table.insert(cond_list, string.format("%s=%s", k, mysql.quote_sql_str(tostring(v))))
    end
    local cond_str = table.concat(cond_list, " AND ")
    local sql = string.format("DELETE FROM %s WHERE %s", _tbl, cond_str)

    local result, err = db:query(sql)
    release(db)

    if not result then
        log.error("[error] MySQL query failed: ", sql, err)
        return nil
    end

    return result
end

function CMD.query_account(account_key)
    local ret = CMD.select("account", { account_key = account_key })
    return ret
end

function CMD.create_account(account_key, account_data)
    local ret = CMD.insert("account", { account_key = account_key, players = account_data.players })
    return ret
end

function CMD.update_account(account_key, account_data)
    local ret = CMD.update("account", { account_key = account_key }, { players = account_data.players })
    return ret
end

function CMD.query_player(player_id)
    local ret = CMD.select("player", { player_id = player_id })
    return ret
end

function CMD.create_player(account_key, player_data)
    local ret = CMD.insert("player", { 
        account_key = account_key, 
        player_name = player_data.player_name, 
        info = player_data.info 
    })
    return ret
end

function CMD.close()
    for _, db in ipairs(pool) do
        db:close()
    end
    pool = {}
    log.info(" MySQL connection closed")
end

function get_connection(_idx)
    if #pool == 0 then
        log.error("[error] No available database connections")
        return nil
    end
    local db = pool[_idx % POOL_SIZE]
    if not db then 
        return pool[1]
    end 
    return db
end

function release(db)
    if db then
        table.insert(pool, db)
    else
        log.error("[error] Attempted to release a nil database connection")
    end
end

function CMD.status()
    return #pool
end

skynet.start(function()
    log.info(" db start")

    skynet.dispatch("lua", function(_, _, cmd, ...)
        local f = CMD[cmd]
        if f then
            skynet.ret(skynet.pack(f(...)))
        else
            log.error("Unknown command: " .. tostring(cmd))
        end
    end)
    skynet.name(".dbc", skynet.self())
    connect({})
end
)