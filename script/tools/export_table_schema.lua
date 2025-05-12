package.path = package.path .. ";./script/?.lua;./script/utils/?.lua"
local skynet = require "skynet"
local mysql = require "skynet.db.mysql"
local cjson = require "cjson"
local log = require "log"
local tableUtils = require "tableUtils"

-- 数据库配置
local db_config = {
    host = "0.0.0.0",
    port = 3306,
    database = "skynet",
    user = "root",
    password = "1234"
}

-- 连接数据库
local function connect_db()
    local db = mysql.connect(db_config)
    if not db then
        error("Failed to connect to database")
    end
    return db
end

-- 获取表结构
local function get_table_schema(db, table_name)
    local sql = string.format("SHOW FULL COLUMNS FROM %s", table_name)
    local result = db:query(sql)
    if not result then
        error("Failed to get table schema: " .. table_name)
    end
    return result
end

-- 获取主键信息
local function get_primary_keys(db, table_name)
    local sql = string.format("SHOW KEYS FROM %s WHERE Key_name = 'PRIMARY'", table_name)
    local result = db:query(sql)
    if not result then
        error("Failed to get primary keys: " .. table_name)
    end
    local primary_keys = {}
    for _, row in ipairs(result) do
        table.insert(primary_keys, row.Column_name)
    end
    return primary_keys
end

-- 获取索引信息
local function get_indexes(db, table_name)
    local sql = string.format("SHOW INDEX FROM %s", table_name)
    local result = db:query(sql)
    if not result then
        error("Failed to get indexes: " .. table_name)
    end
    local indexes = {}
    for _, row in ipairs(result) do
        if row.Key_name ~= "PRIMARY" then
            if not indexes[row.Key_name] then
                indexes[row.Key_name] = {
                    name = row.Key_name,
                    unique = row.Non_unique == 0,
                    columns = {}
                }
            end
            table.insert(indexes[row.Key_name].columns, row.Column_name)
        end
    end
    return indexes
end

-- 生成表配置
local function generate_table_config(table_name, schema, primary_keys, indexes)
    local config = {
        table_name = table_name,
        fields = {},
        primary_keys = primary_keys,
        indexes = indexes,
        non_primary_fields = {}  -- 改为map格式
    }
    
    for _, field in ipairs(schema) do
        local field_name = field.Field
        local field_type = field.Type
        local is_null = field.Null == "YES"
        local is_key = field.Key == "PRI"
        local is_auto_increment = field.Extra == "auto_increment"
        
        -- 构建字段信息
        local field_info = {
            type = field_type,
            is_required = not is_null,
            is_primary = is_key,
            is_auto_increment = is_auto_increment,
            default = field.Default,
            comment = field.Comment
        }
        
        config.fields[field_name] = field_info
        
        -- 收集主键
        if not is_key then
            config.non_primary_fields[field_name] = true
        end
    end
    
    return config
end

-- 导出配置到文件
local function export_to_file(all_configs)
    local file = io.open("script/sql/table_schema.lua", "w")
    if not file then
        error("Failed to open file: table_schema.lua")
    end
    
    file:write("-- 自动生成的表结构配置\n")
    file:write("local config = {\n")
    
    -- 写入每个表的配置
    for table_name, config in pairs(all_configs) do
        file:write(string.format("    [\"%s\"] = {\n", table_name))
        file:write(string.format("        table_name = \"%s\",\n", config.table_name))
        
        -- 写入字段配置
        file:write("        fields = {\n")
        for field_name, field_info in pairs(config.fields) do
            file:write(string.format("            [\"%s\"] = {\n", field_name))
            file:write(string.format("                type = \"%s\",\n", field_info.type))
            file:write(string.format("                is_required = %s,\n", tostring(field_info.is_required)))
            file:write(string.format("                is_primary = %s,\n", tostring(field_info.is_primary)))
            file:write(string.format("                is_auto_increment = %s,\n", tostring(field_info.is_auto_increment)))
            file:write(string.format("                default = %q,\n", tostring(field_info.default)))
            file:write(string.format("                comment = %q,\n", tostring(field_info.comment)))
            file:write("            },\n")
        end
        file:write("        },\n")
        
        -- 写入主键配置
        file:write("        primary_keys = {\n")
        for _, key in ipairs(config.primary_keys) do
            file:write(string.format("            \"%s\",\n", key))
        end
        file:write("        },\n")
        
        -- 写入索引配置
        file:write("        indexes = {\n")
        for index_name, index_info in pairs(config.indexes) do
            file:write(string.format("            [\"%s\"] = {\n", index_name))
            file:write(string.format("                unique = %s,\n", tostring(index_info.unique)))
            file:write("                columns = {\n")
            for _, column in ipairs(index_info.columns) do
                file:write(string.format("                    \"%s\",\n", column))
            end
            file:write("                },\n")
            file:write("            },\n")
        end
        file:write("        },\n")
        
        -- 写入非主键字段map
        file:write("        non_primary_fields = {\n")
        for field, _ in pairs(config.non_primary_fields) do
            file:write(string.format("            [\"%s\"] = true,\n", field))
        end
        file:write("        },\n")
        
        file:write("    },\n")
    end
    
    file:write("}\n")
    file:write("return config\n")
    file:close()
end

-- 主函数
local function main()
    local db = connect_db()
    
    -- 从数据库获取所有表名
    local sql = string.format("SHOW TABLES FROM %s", db_config.database)
    local result = db:query(sql)
    if not result then
        error("Failed to get tables from database")
    end
    
    local tables = {}
    for _, row in ipairs(result) do
        -- SHOW TABLES返回的列名是"Tables_in_数据库名"
        local table_name = row["Tables_in_" .. db_config.database]
        table.insert(tables, table_name)
    end
    
    log.info("Found %d tables in database", #tables)
    
    -- 收集所有表的配置
    local all_configs = {}
    for _, table_name in ipairs(tables) do
        local schema = get_table_schema(db, table_name)
        local primary_keys = get_primary_keys(db, table_name)
        local indexes = get_indexes(db, table_name)
        all_configs[table_name] = generate_table_config(table_name, schema, primary_keys, indexes)
        log.info("Collected table schema: %s", table_name)
    end
    
    -- 导出所有配置到一个文件
    export_to_file(all_configs)
    log.info("Exported all table schemas to table_schema.lua")
end

-- 运行脚本
skynet.start(function()
    main()
    skynet.exit()
end) 