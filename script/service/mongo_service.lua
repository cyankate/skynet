local skynet = require "skynet"
local mongo = require "skynet.db.mongo"
local log = require "log"
local service_ctx = require "runtime.service_ctx"
local collection_schema = require "mongo.collection_schema"

local ctx = service_ctx.get("mongo.mongo", {})
ctx.pool = ctx.pool or {}
ctx.indexes_ready = ctx.indexes_ready or false
ctx.online = ctx.online or false

local pool = ctx.pool
local CMD = {}

local DEFAULT_CONFIG = {
    host = "127.0.0.1",
    port = 27017,
    database = "skynet",
    username = nil,
    password = nil,
    authdb = "admin",
    pool_size = 8,
    max_retry = 3,
    default_limit = 1000,
}

ctx.config = ctx.config or {}
for k, v in pairs(DEFAULT_CONFIG) do
    if ctx.config[k] == nil then
        ctx.config[k] = v
    end
end
local config = ctx.config

local function getenv_str(key)
    local v = skynet.getenv(key)
    if v == nil or v == "" then
        return nil
    end
    return v
end

local function getenv_int(key)
    local v = getenv_str(key)
    if not v then
        return nil
    end
    return tonumber(v)
end

local function apply_env_config()
    config.host = getenv_str("mongo_host") or config.host
    config.port = getenv_int("mongo_port") or config.port
    config.database = getenv_str("mongo_db") or config.database
    config.username = getenv_str("mongo_user") or config.username
    config.password = getenv_str("mongo_password") or config.password
    config.authdb = getenv_str("mongo_authdb") or config.authdb
    config.pool_size = getenv_int("mongo_pool_size") or config.pool_size
    ctx.config = config
end

local function valid_coll(name)
    if type(name) ~= "string" or name == "" then
        return false
    end
    if string.find(name, "%$") or string.find(name, "%.") then
        return false
    end
    return true
end

local function is_operator_doc(doc)
    if type(doc) ~= "table" then
        return false
    end
    for k in pairs(doc) do
        if type(k) == "string" and string.sub(k, 1, 1) == "$" then
            return true
        end
    end
    return false
end

local function wrap_update(update, replace)
    if type(update) ~= "table" then
        return nil, "update must be a table"
    end
    if replace or is_operator_doc(update) then
        return update
    end
    return { ["$set"] = update }
end

local function query_is_empty(query)
    return query == nil or type(query) ~= "table" or next(query) == nil
end

local function copy_docs(docs)
    local copies = {}
    for i, doc in ipairs(docs) do
        local item = {}
        for k, v in pairs(doc) do
            item[k] = v
        end
        copies[i] = item
    end
    return copies
end

local function new_connection()
    local conf = {
        host = config.host,
        port = config.port,
        authdb = config.authdb,
    }
    if config.username and config.password then
        conf.username = config.username
        conf.password = config.password
    end
    local ok, client = pcall(mongo.client, conf)
    if not ok or not client then
        log.error("mongo connect failed: %s", tostring(client))
        return nil
    end
    local db = client:getDB(config.database)
    local ping_ok, ping_ret = pcall(function()
        return db:runCommand("ping")
    end)
    if not ping_ok or not ping_ret or ping_ret.ok ~= 1 then
        pcall(function()
            client:disconnect()
        end)
        log.error("mongo ping failed: %s", tostring(ping_ret))
        return nil
    end
    ctx.online = true
    return { client = client, db = db }
end

local function get_connection()
    local conn = table.remove(pool)
    if conn then
        local ok, ret = pcall(function()
            return conn.db:runCommand("ping")
        end)
        if ok and ret and ret.ok == 1 then
            return conn
        end
        pcall(function()
            conn.client:disconnect()
        end)
    end
    return new_connection()
end

local function release_connection(conn)
    if not conn then
        return
    end
    if #pool < config.pool_size then
        table.insert(pool, conn)
    else
        pcall(function()
            conn.client:disconnect()
        end)
    end
end

local function drop_connection(conn)
    if not conn then
        return
    end
    pcall(function()
        conn.client:disconnect()
    end)
end

local function with_db(fn)
    local last_err
    for _ = 1, config.max_retry do
        local conn = get_connection()
        if not conn then
            last_err = "no mongo connection"
            skynet.sleep(100)
        else
            local packed = { pcall(fn, conn.db) }
            if packed[1] then
                release_connection(conn)
                return table.unpack(packed, 2)
            end
            last_err = packed[2]
            drop_connection(conn)
            log.error("mongo command exception: %s", tostring(last_err))
            skynet.sleep(100)
        end
    end
    return nil, last_err or "mongo command failed after retries"
end

local function get_coll(db, name)
    return db:getCollection(name)
end

local function apply_cursor_options(cursor, options)
    options = options or {}
    if options.sort then
        if type(options.sort) == "table" and options.sort[1] then
            cursor:sort(table.unpack(options.sort))
        else
            cursor:sort(options.sort)
        end
    end
    if options.skip then
        cursor:skip(options.skip)
    end
    if options.limit then
        cursor:limit(options.limit)
    end
    if options.hint then
        cursor:hint(options.hint)
    end
    if options.max_time_ms then
        cursor:maxTimeMS(options.max_time_ms)
    end
    return cursor
end

local function cursor_to_list(cursor)
    local docs = {}
    local ok, err = pcall(function()
        while cursor:hasNext() do
            docs[#docs + 1] = cursor:next()
        end
    end)
    pcall(function()
        cursor:close()
    end)
    if not ok then
        error(err)
    end
    return docs
end

local function build_index_arg(index)
    local arg = {
        name = index.name,
    }
    if index.unique then
        arg.unique = true
    end
    if index.sparse then
        arg.sparse = true
    end
    if index.expireAfterSeconds then
        arg.expireAfterSeconds = index.expireAfterSeconds
    end
    for _, key in ipairs(index.keys or {}) do
        arg[#arg + 1] = key
    end
    return arg
end

local function write_result(ok, err)
    if ok then
        return true
    end
    return false, err
end

local function ensure_collection_indexes(db, coll_name, spec)
    local col = get_coll(db, coll_name)
    for _, index in ipairs(spec.indexes or {}) do
        local arg = build_index_arg(index)
        if #arg == 0 then
            log.warning("mongo index skipped, empty keys: collection=%s name=%s", coll_name, tostring(index.name))
        else
            local ok, ret = pcall(function()
                return col:createIndex(arg)
            end)
            if not ok then
                log.error("mongo createIndex failed: collection=%s name=%s err=%s", coll_name, tostring(index.name), tostring(ret))
            elseif not ret or ret.ok ~= 1 then
                local errmsg = ret and (ret.errmsg or ret.codeName) or "unknown"
                -- 同名同规格索引已存在时 Mongo 会成功；规格冲突才报错
                log.error("mongo createIndex rejected: collection=%s name=%s err=%s", coll_name, tostring(index.name), tostring(errmsg))
            else
                log.info("mongo index ready: collection=%s name=%s", coll_name, tostring(index.name))
            end
        end
    end
    return true
end

local function ensure_all_indexes()
    return with_db(function(db)
        for coll_name, spec in pairs(collection_schema) do
            ensure_collection_indexes(db, coll_name, spec)
        end
        ctx.indexes_ready = true
        return true
    end)
end

function CMD.find(coll_name, query, options)
    if not valid_coll(coll_name) then
        return nil, "invalid collection"
    end
    query = query or {}
    options = options or {}
    local limit = options.limit or config.default_limit
    local projection = options.projection
    return with_db(function(db)
        local cursor = get_coll(db, coll_name):find(query, projection)
        apply_cursor_options(cursor, {
            sort = options.sort,
            skip = options.skip,
            limit = limit,
            hint = options.hint,
            max_time_ms = options.max_time_ms,
        })
        return cursor_to_list(cursor)
    end)
end

function CMD.find_one(coll_name, query, options)
    if not valid_coll(coll_name) then
        return nil, "invalid collection"
    end
    query = query or {}
    options = options or {}
    return with_db(function(db)
        return get_coll(db, coll_name):findOne(query, options.projection)
    end)
end

function CMD.count(coll_name, query)
    if not valid_coll(coll_name) then
        return nil, "invalid collection"
    end
    query = query or {}
    return with_db(function(db)
        local cursor = get_coll(db, coll_name):find(query)
        return cursor:count()
    end)
end

function CMD.find_by_chunk(coll_name, map_id, chunk_ids, extra_query, options)
    if map_id == nil then
        return nil, "map_id required"
    end
    local query = {}
    if type(extra_query) == "table" then
        for k, v in pairs(extra_query) do
            query[k] = v
        end
    end
    query.map_id = map_id
    if type(chunk_ids) == "table" then
        query.chunk_id = { ["$in"] = chunk_ids }
    else
        query.chunk_id = chunk_ids
    end
    return CMD.find(coll_name, query, options)
end

function CMD.insert(coll_name, doc)
    if not valid_coll(coll_name) then
        return false, "invalid collection"
    end
    if type(doc) ~= "table" then
        return false, "doc must be a table"
    end
    if doc._id == nil then
        log.warning("mongo insert without _id: collection=%s", coll_name)
    end
    return write_result(with_db(function(db)
        local ok, err = get_coll(db, coll_name):safe_insert(doc)
        if not ok then
            return false, err
        end
        return true
    end))
end

function CMD.insert_many(coll_name, docs)
    if not valid_coll(coll_name) then
        return false, "invalid collection"
    end
    if type(docs) ~= "table" or #docs == 0 then
        return false, "docs required"
    end
    for i, doc in ipairs(docs) do
        if type(doc) ~= "table" then
            return false, "doc must be a table at index " .. tostring(i)
        end
        if doc._id == nil then
            log.warning("mongo insert_many without _id: collection=%s index=%s", coll_name, tostring(i))
        end
    end
    return write_result(with_db(function(db)
        local ok, err = get_coll(db, coll_name):safe_batch_insert(copy_docs(docs))
        if not ok then
            return false, err
        end
        return true
    end))
end

function CMD.update(coll_name, query, update, options)
    if not valid_coll(coll_name) then
        return false, "invalid collection"
    end
    if query_is_empty(query) then
        return false, "empty query update refused"
    end
    options = options or {}
    local wrapped, wrap_err = wrap_update(update, options.replace)
    if not wrapped then
        return false, wrap_err
    end
    local upsert = options.upsert and true or false
    local multi = options.multi and true or false
    return write_result(with_db(function(db)
        local ok, err = get_coll(db, coll_name):safe_update(query, wrapped, upsert, multi)
        if not ok then
            return false, err
        end
        return true
    end))
end

function CMD.upsert(coll_name, query, update, options)
    options = options or {}
    options.upsert = true
    return CMD.update(coll_name, query, update, options)
end

function CMD.delete(coll_name, query, options)
    if not valid_coll(coll_name) then
        return false, "invalid collection"
    end
    options = options or {}
    if query_is_empty(query) and not options.allow_empty then
        return false, "empty query delete refused"
    end
    local single = not options.multi
    return write_result(with_db(function(db)
        local ok, err = get_coll(db, coll_name):safe_delete(query or {}, single)
        if not ok then
            return false, err
        end
        return true
    end))
end

function CMD.batch_update(coll_name, updates)
    if not valid_coll(coll_name) then
        return false, "invalid collection"
    end
    if type(updates) ~= "table" or #updates == 0 then
        return true
    end
    if #updates > 1000 then
        log.warning("mongo batch_update size=%d collection=%s", #updates, coll_name)
    end
    local packed = {}
    for i, item in ipairs(updates) do
        if type(item) ~= "table" or query_is_empty(item.query) then
            return false, "invalid batch_update item at " .. tostring(i)
        end
        local wrapped, wrap_err = wrap_update(item.update, item.replace)
        if not wrapped then
            return false, wrap_err
        end
        packed[i] = {
            query = item.query,
            update = wrapped,
            upsert = item.upsert and true or false,
            multi = item.multi and true or false,
        }
    end
    return write_result(with_db(function(db)
        local ok, err = get_coll(db, coll_name):safe_batch_update(packed)
        if not ok then
            return false, err
        end
        return true
    end))
end

function CMD.ensure_indexes(coll_name)
    if coll_name then
        if not valid_coll(coll_name) then
            return false, "invalid collection"
        end
        local spec = collection_schema[coll_name]
        if not spec then
            return false, "collection not in schema"
        end
        return with_db(function(db)
            return ensure_collection_indexes(db, coll_name, spec)
        end)
    end
    return ensure_all_indexes()
end

function CMD.ping()
    return with_db(function(db)
        local ret = db:runCommand("ping")
        return ret and ret.ok == 1
    end)
end

function CMD.status()
    return {
        ready = ctx.online and true or false,
        pool_idle = #pool,
        pool_cap = config.pool_size,
        indexes_ready = ctx.indexes_ready and true or false,
        host = config.host,
        port = config.port,
        database = config.database,
    }
end

function CMD.close()
    for _, conn in ipairs(pool) do
        drop_connection(conn)
    end
    pool = {}
    ctx.pool = pool
    ctx.indexes_ready = false
    ctx.online = false
    log.info("mongo connections closed")
    return true
end

function CMD.init(conf)
    apply_env_config()
    if type(conf) == "table" then
        for k, v in pairs(conf) do
            config[k] = v
        end
        ctx.config = config
    end

    for _ = 1, config.pool_size do
        local conn = new_connection()
        if conn then
            table.insert(pool, conn)
        elseif #pool == 0 then
            break
        end
    end

    if #pool == 0 then
        log.error("mongoS init: no connection, will retry on demand. host=%s port=%s db=%s",
            tostring(config.host), tostring(config.port), tostring(config.database))
        return
    end

    log.info("mongoS connected: %d/%d host=%s port=%s db=%s",
        #pool, config.pool_size, tostring(config.host), tostring(config.port), tostring(config.database))
    local ok, err = ensure_all_indexes()
    if not ok then
        log.error("mongoS ensure_indexes failed: %s", tostring(err))
    end
end

return CMD
