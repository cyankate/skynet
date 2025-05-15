
local skynet = require "skynet"
local mysql = require "skynet.db.mysql"
local sprotoloader = require "sprotoloader"
local tableUtils = require "utils.tableUtils"
local log = require "log"
local table_schema = require "sql.table_schema"
require "skynet.manager"
local IDGenerator = require "utils.id_generator"
local service_wrapper = require "utils.service_wrapper"

local pool = {}
local POOL_SIZE = 10

local DB_CONNECTION = {
    host = "127.0.0.1",
    port = 3306,
    database = "skynet",
    user = "root",
    password = "1234",
    max_packet_size = 1024 * 1024,
}

local id_generator

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
    -- 参数检查
    if not _tbl then
        log.error("Table name is required")
        return nil
    end
    
    -- 检查表是否存在
    if not table_schema[_tbl] then
        log.error("Table %s not found", _tbl)
        return nil
    end
    
    local lba = _options and _options.lba or 0
    local db = get_connection(lba)
    if not db then
        log.error("No available database connections")
        return nil
    end
    
    -- 处理字段筛选
    local fields_str = "*"
    if _options and _options.fields and #_options.fields > 0 then
        -- 验证字段是否存在
        local valid_fields = {}
        for _, field in ipairs(_options.fields) do
            if table_schema[_tbl].fields[field] then
                table.insert(valid_fields, string.format("`%s`", field))
            else
                log.warn("Field %s not found in table %s", field, _tbl)
            end
        end
        
        if #valid_fields > 0 then
            fields_str = table.concat(valid_fields, ", ")
        end
    end
    
    -- 处理WHERE条件
    local where_clause = ""
    if _cond and next(_cond) then
        local cond_list = {}
        for k, v in pairs(_cond) do
            -- 验证字段是否存在
            if not table_schema[_tbl].fields[k] then
                log.warn("Condition field %s not found in table %s", k, _tbl)
                goto continue
            end
            
            local field_type = table_schema[_tbl].fields[k].type
            -- 根据字段类型处理值
            if field_type:find("varchar") or field_type == "text" then
                table.insert(cond_list, string.format("`%s`=%s", k, mysql.quote_sql_str(tostring(v))))
            else
                table.insert(cond_list, string.format("`%s`=%s", k, tostring(v)))
            end
            
            ::continue::
        end
        
        if #cond_list > 0 then
            where_clause = " WHERE " .. table.concat(cond_list, " AND ")
        end
    end
    
    -- 处理排序
    local order_clause = ""
    if _options and _options.order_by then
        local valid_orders = {}
        for field, direction in pairs(_options.order_by) do
            if table_schema[_tbl].fields[field] then
                local dir = string.upper(direction or "ASC")
                if dir ~= "ASC" and dir ~= "DESC" then
                    dir = "ASC"
                end
                table.insert(valid_orders, string.format("`%s` %s", field, dir))
            else
                log.warn("Order field %s not found in table %s", field, _tbl)
            end
        end
        
        if #valid_orders > 0 then
            order_clause = " ORDER BY " .. table.concat(valid_orders, ", ")
        end
    end
    
    -- 处理分页
    local limit_clause = ""
    if _options and _options.limit then
        local limit = tonumber(_options.limit)
        if limit and limit > 0 then
            limit_clause = string.format(" LIMIT %d", limit)
            
            -- 处理偏移
            if _options.offset then
                local offset = tonumber(_options.offset)
                if offset and offset >= 0 then
                    limit_clause = limit_clause .. string.format(" OFFSET %d", offset)
                end
            end
        end
    end
    
    -- 构建完整的查询语句
    local sql = string.format("SELECT %s FROM `%s`%s%s%s", 
        fields_str, 
        _tbl,
        where_clause,
        order_clause,
        limit_clause
    )
    
    -- 执行查询
    --log.debug("SQL: %s", sql)
    local result, err = db:query(sql)
    release(db)
    
    if not result then
        log.error("MySQL query failed: %s, %s", sql, err)
        return nil
    end

    for _, row in ipairs(result) do
        for field, value in pairs(row) do
            local field_type = table_schema[_tbl].fields[field].type
            if field_type == "text" then
                row[field] = tableUtils.deserialize_table(value)
            end
        end
    end
    return result
end

function CMD.insert(_tbl, _data, _options)
    local lba = _options and _options.lba or 0
    local db = get_connection(lba)
    if not db then
        log.error("No available database connections")
        return nil
    end

    -- 检查表是否存在
    if not table_schema[_tbl] then
        log.error("Table %s not found", _tbl)
        return nil
    end

    local schema_fields = table_schema[_tbl].fields
    local fields = {}
    local values = {}

    -- 检查必填字段
    for field_name, field_info in pairs(schema_fields) do
        -- 跳过自增长字段
        if field_info.is_auto_increment then
            goto continue
        end

        -- 检查必填字段
        if field_info.is_required and not _data[field_name] then
            log.error("dbS:insert TBL %s FIELD %s is required", _tbl, field_name)
            return nil
        end

        -- 如果字段有值，检查类型和长度
        if _data[field_name] then
            local value = _data[field_name]
            local field_type = field_info.type

            -- 检查数值类型
            if field_type == "int" and type(value) ~= "number" then
                log.error("dbS:insert TBL %s FIELD %s type error, not number", _tbl, field_name)
                return nil
            end

            -- 检查varchar类型
            if field_type:find("varchar") then
                if type(value) ~= "string" then
                    log.error("dbS:insert TBL %s FIELD %s type error, not string", _tbl, field_name)
                    return nil
                end
                local limit = tonumber(string.match(field_type, "varchar%((%d+)%)"))
                if #value > limit then
                    log.error("dbS:insert TBL %s FIELD %s type error, string length too long", _tbl, field_name)
                    return nil
                end
            end

            -- 处理text类型
            if field_type == "text" and type(value) == "table" then
                table.insert(values, mysql.quote_sql_str(tableUtils.serialize_table(value)))
            else
                table.insert(values, mysql.quote_sql_str(tostring(value)))
            end
            table.insert(fields, field_name)
        end

        ::continue::
    end

    -- 构建SQL语句
    local fields_str = table.concat(fields, ",")
    local values_str = table.concat(values, ",")
    local sql = string.format("INSERT INTO `%s` (%s) VALUES (%s)", _tbl, fields_str, values_str)

    -- 执行SQL
    local result, err = db:query(sql)
    release(db)

    if result.badresult then
        log.error("MySQL insert failed: %s, %s", sql, tableUtils.serialize_table(result))
        return nil
    end

    return result
end

function CMD.update(_tbl, _data, _options)
    local lba = _options and _options.lba or 0
    local db = get_connection(lba)
    if not db then
        log.error("No available database connections")
        return nil
    end

    -- 检查表是否存在
    if not table_schema[_tbl] then
        log.error("Table %s not found", _tbl)
        return nil
    end

    local schema_fields = table_schema[_tbl].fields
    local primary_keys = table_schema[_tbl].primary_keys
    local non_primary_fields = table_schema[_tbl].non_primary_fields
    local set_list = {}
    local where_list = {}

    -- 检查主键字段
    for _, pk in ipairs(primary_keys) do
        if not _data[pk] then
            log.error("dbS:update TBL %s primary key %s not found", _tbl, pk)
            return nil
        end
        table.insert(where_list, string.format("%s=%s", pk, mysql.quote_sql_str(tostring(_data[pk]))))
    end

    -- 检查非主键字段
    for field_name, _ in pairs(non_primary_fields) do
        if _data[field_name] then
            local value = _data[field_name]
            local field_info = schema_fields[field_name]
            local field_type = field_info.type

            -- 检查数值类型
            if field_type == "int" and type(value) ~= "number" then
                log.error("dbS:update TBL %s FIELD %s type error, not number", _tbl, field_name)
                return nil
            end

            -- 检查varchar类型
            if field_type:find("varchar") then
                if type(value) ~= "string" then
                    log.error("dbS:update TBL %s FIELD %s type error, not string", _tbl, field_name)
                    return nil
                end
                local limit = tonumber(string.match(field_type, "varchar%((%d+)%)"))
                if #value > limit then
                    log.error("dbS:update TBL %s FIELD %s type error, string length too long", _tbl, field_name)
                    return nil
                end
            end

            -- 处理text类型
            if field_type == "text" and type(value) == "table" then
                table.insert(set_list, string.format("%s=%s", field_name, mysql.quote_sql_str(tableUtils.serialize_table(value))))
            else
                table.insert(set_list, string.format("%s=%s", field_name, mysql.quote_sql_str(tostring(value))))
            end
        end
    end

    -- 如果没有要更新的字段，直接返回成功
    if #set_list == 0 then
        log.warn("dbS:update TBL %s No fields to update", _tbl)
        return {affected_rows = 0}  -- 返回一个模拟的成功结果
    end

    -- 构建SQL语句
    local set_str = table.concat(set_list, ",")
    local where_str = table.concat(where_list, " AND ")
    local sql = string.format("UPDATE `%s` SET %s WHERE %s", _tbl, set_str, where_str)

    --log.debug("dbS:update %s", sql)
    local result, err = db:query(sql)
    release(db)

    if result.badresult then
        log.error("MySQL update failed %s, %s", sql, tableUtils.serialize_table(result))
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
    local sql = string.format("DELETE FROM `%s` WHERE %s", _tbl, cond_str)

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
    local ret = CMD.update("account", { account_key = account_key, players = account_data.players })
    return ret
end

-- 更新账号登录信息
function CMD.update_account_login(account_key, ip, login_time, device_id)
    local data = {
        account_key = account_key,
        last_login_ip = ip,
        last_login_time = os.date("%Y-%m-%d %H:%M:%S", login_time) -- 转换为datetime格式
    }
    
    -- 只有当设备ID存在时才更新
    if device_id and device_id ~= "unknown" then
        data.device_id = device_id
    end
    
    local ret = CMD.update("account", data)
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

-- 获取表的最大ID
function CMD.get_max_id(table_name, id_field)
    local db = get_connection(0)
    if not db then
        log.error("[error] No available database connections")
        return nil
    end
    local result, err = db:query(string.format("SELECT MAX(%s) as max_id FROM `%s`", id_field, table_name))
    release(db)
    
    if result and result[1] then
        return result[1].max_id
    end
    return nil
end

-- 生成ID
function CMD.gen_id(type_name)
    return id_generator:gen_id(type_name)
end

function CMD.load_friend_data(player_id)
    local ret = CMD.select("friend", { player_id = player_id })
    if ret and ret[1] then
        return ret[1].data
    end
    return nil
end

function CMD.create_friend_data(player_id, data)
    local ret = CMD.insert("friend", { player_id = player_id, data = data })
    return ret
end

function CMD.save_friend_data(player_id, data)
    local ret = CMD.update("friend", { player_id = player_id, data = data })
    return ret
end

service_wrapper.create_service(function()
    skynet.name(".db", skynet.self())
    connect({})
    if not id_generator then
        id_generator = IDGenerator.new()
    end
end, {
    name = "db",
    register_hotfix = false,
})