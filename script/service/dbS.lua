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
    local struct = table_schema[_tbl]
    local lba = _options and _options.lba or 0
    local db = get_connection(lba)
    if not db then
        log.error("No available database connections")
        return nil
    end
    
    -- 处理字段筛选
    local fields_str = "*"
    if _options and _options.fields and #_options.fields > 0 then
        local valid_fields = {}
        for _, field in ipairs(_options.fields) do
            -- 检查是否是聚合函数或特殊表达式
            if string.find(field, "[%(%)]") then
                -- 直接添加聚合函数或特殊表达式
                table.insert(valid_fields, field)
            else
                -- 检查普通字段是否存在
                if struct.fields[field] then
                    table.insert(valid_fields, string.format("`%s`", field))
                else
                    log.warning("Field %s not found in table %s", field, _tbl)
                end
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
            if not struct.fields[k] then
                log.warning("Condition field %s not found in table %s", k, _tbl)
                goto continue
            end
            local field_type = struct.fields[k].type
            -- 处理IN查询
            if type(v) == "table" and #v > 0 then
                local values = {}
                for _, item in ipairs(v) do
                    if field_type:find("varchar") or field_type == "text" then
                        table.insert(values, mysql.quote_sql_str(tostring(item)))
                    else
                        table.insert(values, tostring(item))
                    end
                end
                table.insert(cond_list, string.format("`%s` IN (%s)", k, table.concat(values, ",")))
            -- 处理复杂条件(比如 > < >= <= 等)
            elseif type(v) == "table" and next(v) then
                for op, val in pairs(v) do
                    if op == ">" or op == "<" or op == ">=" or op == "<=" or op == "!=" then
                        if field_type:find("varchar") or field_type == "text" then
                            table.insert(cond_list, string.format("`%s`%s%s", k, op, mysql.quote_sql_str(tostring(val))))
                        else
                            table.insert(cond_list, string.format("`%s`%s%s", k, op, tostring(val)))
                        end
                    end
                end
            -- 处理普通条件
            else
                if field_type:find("varchar") or field_type == "text" then
                    table.insert(cond_list, string.format("`%s`=%s", k, mysql.quote_sql_str(tostring(v))))
                else
                    table.insert(cond_list, string.format("`%s`=%s", k, tostring(v)))
                end
            end
            
            ::continue::
        end
        if #cond_list > 0 then
            where_clause = " WHERE " .. table.concat(cond_list, " AND ")
        else
            log.error("where_clause is empty, tbl: %s, cond: %s", _tbl, tableUtils.serialize_table(_cond))
            return nil 
        end
    end
    
    -- 处理GROUP BY
    local group_clause = ""
    if _options and _options.group_by then
        if type(_options.group_by) == "string" then
            if struct.fields[_options.group_by] then
                group_clause = string.format(" GROUP BY `%s`", _options.group_by)
            end
        elseif type(_options.group_by) == "table" then
            local valid_fields = {}
            for _, field in ipairs(_options.group_by) do
                if struct.fields[field] then
                    table.insert(valid_fields, string.format("`%s`", field))
                end
            end
            if #valid_fields > 0 then
                group_clause = " GROUP BY " .. table.concat(valid_fields, ", ")
            end
        end
    end
    
    -- 处理HAVING
    local having_clause = ""
    if _options and _options.having then
        having_clause = " HAVING " .. _options.having
    end
    
    -- 处理排序
    local order_clause = ""
    if _options and _options.order_by then
        local orders = {}
        for field, direction in pairs(_options.order_by) do
            direction = direction:upper()
            if direction ~= "ASC" and direction ~= "DESC" then
                direction = "ASC"
            end
            -- 支持聚合函数排序
            if string.find(field, "[%(%)]") then
                table.insert(orders, string.format("%s %s", field, direction))
            elseif struct.fields[field] then
                table.insert(orders, string.format("`%s` %s", field, direction))
            end
        end
        if #orders > 0 then
            order_clause = " ORDER BY " .. table.concat(orders, ", ")
        end
    end
    
    -- 处理分页
    local limit_clause = ""
    if _options and _options.limit then
        limit_clause = string.format(" LIMIT %d", _options.limit)
        if _options.offset then
            limit_clause = limit_clause .. string.format(" OFFSET %d", _options.offset)
        end
    end
    
    -- 构建完整SQL
    local sql = string.format("SELECT %s FROM `%s`%s%s%s%s%s",
        fields_str, _tbl, where_clause, group_clause, having_clause, order_clause, limit_clause)
    
    -- 执行查询
    local result = db:query(sql)
    release(db)
    
    if result and result.badresult then
        log.error("MySQL query failed: %s, err: %s", sql, result.err)
        return nil
    end

    for _, row in ipairs(result) do
        for field, value in pairs(row) do
            if struct.fields[field] then
                local field_type = struct.fields[field].type
                if field_type == "text" then
                    row[field] = tableUtils.deserialize_table(value)
                end
            end
        end
    end
    return result
end

function CMD.batch_insert(_tbl, _data_list, _options)
    -- 参数验证
    if not _tbl or not _data_list then
        log.error("Table name and data list are required")
        return nil
    end

    -- 获取数据库连接
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

    -- 如果是空列表，直接返回
    if #_data_list == 0 then
        return {affected_rows = 0}
    end

    -- 分批处理的大小
    local BATCH_SIZE = 1000
    local total_affected_rows = 0

    -- 开始事务
    local ret = db:query("START TRANSACTION")
    if ret and ret.badresult then
        log.error("Failed to start transaction: %s", ret.badresult)
        release(db)
        return nil
    end

    local success = true
    local err_msg

    -- 分批处理
    for i = 1, #_data_list, BATCH_SIZE do
        local batch = {}
        for j = i, math.min(i + BATCH_SIZE - 1, #_data_list) do
            table.insert(batch, _data_list[j])
        end

        local schema_fields = table_schema[_tbl].fields
        local fields = {}
        local all_values = {}
        local field_map = {}  -- 用于记录字段位置

        -- 处理第一条数据来确定字段列表
        local first_data = batch[1]
        local field_idx = 1
        for field_name, field_info in pairs(schema_fields) do
            -- 跳过自增长字段
            if field_info.is_auto_increment then
                goto continue
            end

            -- 检查必填字段
            if field_info.is_required and first_data[field_name] == nil then
                log.error("dbS:batch_insert TBL %s FIELD %s is required", _tbl, field_name)
                success = false
                err_msg = string.format("Required field %s is missing", field_name)
                break
            end

            -- 如果字段有值或允许为NULL，添加到字段列表
            if first_data[field_name] ~= nil or not field_info.is_required then
                table.insert(fields, field_name)
                field_map[field_name] = field_idx
                field_idx = field_idx + 1
            end

            ::continue::
        end

        if not success then
            break
        end

        -- 处理所有数据
        for _, data in ipairs(batch) do
            local values = {}
            for i = 1, #fields do values[i] = "NULL" end  -- 预填充NULL

            for field_name, value in pairs(data) do
                local idx = field_map[field_name]
                if idx then
                    local field_info = schema_fields[field_name]
                    local field_type = field_info.type

                    -- 检查数值类型
                    if field_type == "int" and type(value) ~= "number" then
                        success = false
                        err_msg = string.format("Field %s type error, not number", field_name)
                        break
                    end

                    -- 检查varchar类型
                    if field_type:find("varchar") then
                        if type(value) ~= "string" then
                            success = false
                            err_msg = string.format("Field %s type error, not string", field_name)
                            break
                        end
                        local limit = tonumber(string.match(field_type, "varchar%((%d+)%)"))
                        if #value > limit then
                            success = false
                            err_msg = string.format("Field %s type error, string length too long", field_name)
                            break
                        end
                    end

                    -- 处理text类型
                    if field_type == "text" and type(value) == "table" then
                        values[idx] = mysql.quote_sql_str(tableUtils.serialize_table(value))
                    else
                        values[idx] = mysql.quote_sql_str(tostring(value))
                    end
                end
            end

            if not success then
                break
            end

            table.insert(all_values, "(" .. table.concat(values, ",") .. ")")
        end

        if not success then
            break
        end

        -- 构建SQL语句
        local fields_str = "`" .. table.concat(fields, "`,`") .. "`"
        local values_str = table.concat(all_values, ",")
        local sql = string.format("INSERT INTO `%s` (%s) VALUES %s", _tbl, fields_str, values_str)

        -- 执行SQL
        local result = db:query(sql)
        if result and result.badresult then
            success = false
            err_msg = result.badresult
            log.error("MySQL batch insert failed: tbl: %s, err: %s", _tbl, tableUtils.serialize_table(result))
            break
        end

        total_affected_rows = total_affected_rows + (result.affected_rows or 0)
    end

    -- 事务处理
    if success then
        local ret = db:query("COMMIT")
        if ret and ret.badresult then
            log.error("Failed to commit transaction: %s", ret.badresult)
            db:query("ROLLBACK")
            release(db)
            return nil
        end
        release(db)
        return {affected_rows = total_affected_rows}
    else
        db:query("ROLLBACK")
        release(db)
        log.error("Batch insert failed: %s", err_msg)
        return nil
    end
end

function CMD.insert(_tbl, _data, _options)
    return CMD.batch_insert(_tbl, {_data}, _options)
end

function CMD.batch_update(_tbl, _data_list, _options)
    -- 参数验证
    if not _tbl or not _data_list then
        log.error("Table name and data list are required")
        return nil
    end

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

    -- 如果是空列表，直接返回
    if #_data_list == 0 then
        return {affected_rows = 0}
    end

    -- 分批处理的大小
    local BATCH_SIZE = 1000
    local total_affected_rows = 0

    local schema_fields = table_schema[_tbl].fields
    local primary_keys = table_schema[_tbl].primary_keys
    local non_primary_fields = table_schema[_tbl].non_primary_fields

    -- 开始事务
    local _, err = db:query("START TRANSACTION")
    if err then
        log.error("Failed to start transaction: %s", err)
        release(db)
        return nil
    end

    local success = true
    local err_msg

    -- 分批处理
    for i = 1, #_data_list, BATCH_SIZE do
        local batch = {}
        for j = i, math.min(i + BATCH_SIZE - 1, #_data_list) do
            table.insert(batch, _data_list[j])
        end

        -- 收集所有要更新的字段
        local update_fields = {}
        local first_data = batch[1]
        
        -- 从第一条数据中收集非主键字段
        for field_name, _ in pairs(non_primary_fields) do
            if first_data[field_name] ~= nil then
                -- 验证字段类型
                local field_info = schema_fields[field_name]
                local field_type = field_info.type
                local value = first_data[field_name]

                -- 检查数值类型
                if field_type == "int" and type(value) ~= "number" then
                    success = false
                    err_msg = string.format("Field %s type error, not number", field_name)
                    break
                end

                -- 检查varchar类型
                if field_type:find("varchar") then
                    if type(value) ~= "string" then
                        success = false
                        err_msg = string.format("Field %s type error, not string", field_name)
                        break
                    end
                    local limit = tonumber(string.match(field_type, "varchar%((%d+)%)"))
                    if #value > limit then
                        success = false
                        err_msg = string.format("Field %s type error, string length too long", field_name)
                        break
                    end
                end

                table.insert(update_fields, field_name)
            end
        end

        if not success or #update_fields == 0 then
            if #update_fields == 0 then
                err_msg = "No fields to update"
            end
            break
        end

        -- 构建CASE语句
        local case_whens = {}
        local where_values = {}
        
        for _, data in ipairs(batch) do
            -- 检查主键
            local pk_conditions = {}
            for _, pk in ipairs(primary_keys) do
                if data[pk] == nil then
                    success = false
                    err_msg = string.format("Primary key %s not found", pk)
                    break
                end
                table.insert(pk_conditions, mysql.quote_sql_str(tostring(data[pk])))
            end

            if not success then
                break
            end
            
            -- 检查和处理更新字段
            for _, field_name in ipairs(update_fields) do
                local value = data[field_name]
                if value ~= nil then
                    local field_info = schema_fields[field_name]
                    local field_type = field_info.type

                    -- 为每个字段构建CASE WHEN语句
                    if not case_whens[field_name] then
                        case_whens[field_name] = {}
                    end
                    
                    local when_condition = table.concat(pk_conditions, " AND ")
                    local quoted_value
                    if field_type == "text" and type(value) == "table" then
                        quoted_value = mysql.quote_sql_str(tableUtils.serialize_table(value))
                    else
                        quoted_value = mysql.quote_sql_str(tostring(value))
                    end
                    
                    table.insert(case_whens[field_name], 
                        string.format("WHEN %s THEN %s", 
                            when_condition, 
                            quoted_value
                        )
                    )
                end
            end
            
            -- 收集WHERE条件的值
            table.insert(where_values, table.concat(pk_conditions, ","))
        end

        if not success then
            break
        end

        -- 构建SET子句
        local set_list = {}
        for field_name, whens in pairs(case_whens) do
            if #whens > 0 then
                local case_str = string.format("`%s` = CASE %s %s END",
                    field_name,
                    table.concat(primary_keys, ","),
                    table.concat(whens, " ")
                )
                table.insert(set_list, case_str)
            end
        end

        -- 构建WHERE子句
        local where_str
        if #primary_keys == 1 then
            where_str = string.format("`%s` IN (%s)",
                primary_keys[1],
                table.concat(where_values, ",")
            )
        else
            where_str = string.format("(%s) IN ((%s))",
                table.concat(primary_keys, ","),
                table.concat(where_values, "),(")
            )
        end

        -- 构建完整的SQL语句
        local sql = string.format("UPDATE `%s` SET %s WHERE %s",
            _tbl,
            table.concat(set_list, ", "),
            where_str
        )
        -- 执行SQL
        local result = db:query(sql)
        if not result or result.badresult then
            success = false
            err_msg = err or "Unknown error"
            break
        end

        total_affected_rows = total_affected_rows + (result.affected_rows or 0)
    end

    -- 事务处理
    if success then
        local result = db:query("COMMIT")
        if err then
            log.error("Failed to commit transaction: %s", err)
            db:query("ROLLBACK")
            release(db)
            return nil
        end
        release(db)
        return {affected_rows = total_affected_rows}
    else
        db:query("ROLLBACK")
        release(db)
        log.error("Batch update failed: tbl: %s, err: %s", _tbl, err_msg)
        return nil
    end
end

function CMD.update(_tbl, _data, _options)
    return CMD.batch_update(_tbl, {_data}, _options)
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

    local result = db:query(sql)
    release(db)

    if not result then
        log.error("[error] MySQL query failed: tbl: %s, cond: %s", _tbl, cond_str)
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
    if ret and ret[1] then
        return ret[1]
    end
    return nil
end

function CMD.create_player(player_id, player_data)
    local ret = CMD.insert("player", { 
        player_id = player_id,
        account_key = player_data.account_key, 
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
    local result = db:query(string.format("SELECT MAX(%s) as max_id FROM `%s`", id_field, table_name))
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

function CMD.get_max_channel_id()
    local ret = CMD.select("channel", { }, { order_by = { channel_id = "DESC" }, limit = 1 })
    if ret and ret[1] then
        return ret[1].channel_id
    end
    return nil
end

function CMD.get_private_channel(player_id, to_player_id)
    if player_id > to_player_id then 
        player_id, to_player_id = to_player_id, player_id
    end 
    local ret = CMD.select("private_channel", { player1_id = player_id, player2_id = to_player_id })
    if ret and ret[1] then
        return ret[1]
    end
    return nil
end 

function CMD.create_private_channel(data)
    local ret = CMD.insert("private_channel", data)
    return ret
end

service_wrapper.create_service(function()
    skynet.name(".db", skynet.self())
    connect()
    if not id_generator then
        id_generator = IDGenerator.new()
    end
end, {
    name = "db",
    register_hotfix = false,
})