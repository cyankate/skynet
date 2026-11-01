local skynet = require "skynet"
local CtnBase = require "ctn.ctn_base"
local tableUtils = require "utils.tableUtils"
local log = require "log"
local table_schema = require "sql/table_schema"
local db_call = require "system.db_call"

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

-- 主键字符串（player_id_idx 形式），doload / dosave / 关键提交共用
function CtnMf:prikeys_str(data)
    local primary_keys = table_schema[self.tbl_].primary_keys
    local vals = {}
    for _, field in ipairs(primary_keys) do
        if data[field] ~= nil then
            vals[#vals + 1] = tostring(data[field])
        end
    end
    return table.concat(vals, "_")
end

-- 从数据库加载数据
function CtnMf:doload()
    local cond = {player_id = self.prikey_}
    local ret = db_call.call("select", self.tbl_, cond, {lba = self.prikey_})

    if not ret or ret.badresult then
        self:set_error("Failed to load data from database")
        return false, ERROR_CODE.DB_ERROR
    end
    for _, row in ipairs(ret) do
        self.sub_inserted_[self:prikeys_str(row)] = true
    end
    self:onload(ret)

    return true
end

-- 保存数据到数据库：批量插入/更新，返回成功或失败
function CtnMf:dosave()
    local datas, err_code = self:onsave()
    if not datas then
        return false, err_code
    end

    local fields = table_schema[self.tbl_].fields
    local insert_rows, update_rows = {}, {}
    for _, data in pairs(datas) do
        local values = {}
        for field, _ in pairs(fields) do
            if data[field] ~= nil then
                values[field] = data[field]
            end
        end
        local key = self:prikeys_str(values)
        if not self.sub_inserted_[key] then
            insert_rows[#insert_rows + 1] = values
        else
            update_rows[#update_rows + 1] = values
        end
    end

    if #insert_rows > 0 then
        local ret = db_call.call("batch_insert", self.tbl_, insert_rows, { lba = self.prikey_ })
        if not ret then
            return false, "batch_insert failed"
        end
        for _, row in ipairs(insert_rows) do
            self.sub_inserted_[self:prikeys_str(row)] = true
        end
    end
    if #update_rows > 0 then
        local ret = db_call.call("batch_update", self.tbl_, update_rows, { lba = self.prikey_ })
        if not ret then
            return false, "batch_update failed"
        end
    end

    return true
end

-- 把对应行标记为已入库，使定时保存走 update
function CtnMf:mark_rows_saved(rows)
    for _, row in ipairs(rows or {}) do
        self.sub_inserted_[self:prikeys_str(row)] = true
    end
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
