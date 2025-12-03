local skynet = require "skynet"
local CtnBase = require "ctn.ctn_base"
local tableUtils = require "utils.tableUtils"
local log = require "log"
local table_schema = require "sql/table_schema"

local CtnMf = class("CtnMf", CtnBase)

-- 错误码
local ERROR_CODE = {
    SUCCESS = 0,           -- 成功
    NOT_LOADED = 1,        -- 数据未加载
    INVALID_DATA = 2,      -- 无效数据
    DB_ERROR = 3,          -- 数据库错误
    DUPLICATE_KEY = 4,     -- 重复键
    KEY_NOT_FOUND = 5,     -- 键不存在
    MERGE_ERROR = 6,       -- 合并错误
}

function CtnMf:ctor(_player_id, _tbl, _name)
    CtnBase.ctor(self, _player_id, _name)
    self.tbl_ = _tbl
    self.prikey_ = _player_id
    self.datas_ = {}       -- 所有数据
    self.sub_inserted_ = {} -- 字段插入标记
    self.last_save_time_ = 0
    self.auto_save_interval_ = 300
    self.max_data_size_ = 1024 * 1024 -- 最大数据大小（1MB）
    self.prikey_list_ = {}
end 

-- 设置最大数据大小
function CtnMf:set_max_data_size(size)
    self.max_data_size_ = size
end

-- 从数据库加载数据
function CtnMf:doload()
    local dbc = skynet.localname(".db")
    local cond = {player_id = self.prikey_}
    local ret = skynet.call(dbc, "lua", "select", self.tbl_, cond, {lba = self.prikey_})
    
    if ret.badresult then
        self:set_error("Failed to load data from database")
        return false, ERROR_CODE.DB_ERROR
    end
    local primary_keys = table_schema[self.tbl_].primary_keys
    for _, row in ipairs(ret) do
        -- 构建主键字符串作为唯一标识
        local prikeys_values = {}
        for _, field in pairs(primary_keys) do
            if row[field] then
                table.insert(prikeys_values, tostring(row[field]))
            end
        end
        local prikeys_str = table.concat(prikeys_values, "_")
        self.sub_inserted_[prikeys_str] = true
    end
    self:onload(ret)
    
    return true
end

-- 保存数据到数据库
function CtnMf:dosave()
    -- 获取需要保存的数据
    local datas, err_code = self:onsave()
    if not datas then
        return false, err_code
    end
    
    -- 获取表结构信息
    local primary_keys = table_schema[self.tbl_].primary_keys
    local non_primary_fields = table_schema[self.tbl_].non_primary_fields
    local fields = table_schema[self.tbl_].fields
    
    -- 获取数据库连接
    local dbc = skynet.localname(".db")
    -- 遍历所有数据行
    for _, data in pairs(datas) do
        -- 提取有效字段值
        local values = {}
        for field, _ in pairs(fields) do
            if data[field] then
                values[field] = data[field]
            end
        end
        
        -- 构建主键字符串作为唯一标识
        local prikeys_values = {}
        for _, field in pairs(primary_keys) do
            if data[field] then
                table.insert(prikeys_values, tostring(data[field]))
            end
        end
        local prikeys_str = table.concat(prikeys_values, "_")
        
        -- 根据是否已插入决定执行insert还是update
        if not self.sub_inserted_[prikeys_str] then
            -- 执行插入操作
            local ret = skynet.call(dbc, "lua", "insert", self.tbl_, values)
            if not ret then
                error(string.format("Failed to insert data with primary keys: %s", prikeys_str))
                return
            end
            self.sub_inserted_[prikeys_str] = true
        else 
            -- 执行更新操作
            skynet.send(dbc, "lua", "update", self.tbl_, values)
        end 
    end
    
    return true
end

-- 获取所有字段
function CtnMf:get_all_fields()
    if not self:is_loaded() then
        return nil, ERROR_CODE.NOT_LOADED
    end
    
    local fields = {}
    for field in pairs(self.datas_) do
        table.insert(fields, field)
    end
    return fields
end

-- 获取所有值
function CtnMf:get_all_values()
    if not self:is_loaded() then
        return nil, ERROR_CODE.NOT_LOADED
    end
    
    local values = {}
    for _, value in pairs(self.datas_) do
        table.insert(values, value)
    end
    return values
end

-- 检查字段是否存在
function CtnMf:has_field(field)
    if not self:is_loaded() then
        return false, ERROR_CODE.NOT_LOADED
    end
    return self.datas_[field] ~= nil
end

-- 获取数据大小
function CtnMf:get_data_size()
    if not self:is_loaded() then
        return 0, ERROR_CODE.NOT_LOADED
    end
    
    local size = #tableUtils.serialize_table(self.datas_)
    return size
end

-- 清空数据
function CtnMf:clear()
    if not self:is_loaded() then
        return false, ERROR_CODE.NOT_LOADED
    end
    
    for field in pairs(self.datas_) do
        self:set_field_dirty(field)
    end
    self.datas_ = {}
    return true
end

-- 获取数据统计信息
function CtnMf:get_stats()
    if not self:is_loaded() then
        return nil, ERROR_CODE.NOT_LOADED
    end
    
    local stats = {
        field_count = self:get_item_count(),
        data_size = self:get_data_size(),
        max_size = self.max_data_size_,
        last_save_time = self.last_save_time_,
        is_dirty = self:is_dirty(),
        dirty_fields = self:get_dirty_fields(),
        merge_strategy = self.merge_strategy_,
    }
    return stats
end

return CtnMf
