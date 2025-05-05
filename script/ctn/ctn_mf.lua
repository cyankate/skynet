package.path = package.path .. ";./script/?.lua;./script/utils/?.lua"
local skynet = require "skynet"
local ctn_base = require "ctn.ctn_base"
local class = require "utils.class"
local tableUtils = require "utils.tableUtils"
local log = require "log"

local ctn_mf = class("ctn_mf", ctn_base)

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

-- 合并策略
local MERGE_STRATEGY = {
    REPLACE = 1,           -- 替换
    MERGE = 2,             -- 合并
    KEEP_OLD = 3,          -- 保留旧值
    KEEP_NEW = 4,          -- 保留新值
}

function ctn_mf:ctor(_player_id, _tbl, _name)
    ctn_base.ctor(self, _player_id, _name)
    self.tbl_ = _tbl
    self.prikey_ = _player_id
    self.datas_ = {}       -- 所有数据
    self.field_dirty_ = {} -- 字段脏标记
    self.last_save_time_ = 0
    self.auto_save_interval_ = 300
    self.max_data_size_ = 1024 * 1024 -- 最大数据大小（1MB）
    self.merge_strategy_ = MERGE_STRATEGY.REPLACE -- 默认合并策略
end

-- 设置合并策略
function ctn_mf:set_merge_strategy(strategy)
    self.merge_strategy_ = strategy
end

-- 设置最大数据大小
function ctn_mf:set_max_data_size(size)
    self.max_data_size_ = size
end

-- 检查数据大小是否合法
function ctn_mf:check_data_size(data)
    local size = #tableUtils.serialize_table(data)
    return size <= self.max_data_size_, size
end

-- 标记字段为脏
function ctn_mf:set_field_dirty(field)
    self.field_dirty_[field] = true
    self:set_dirty()
end

-- 清除字段脏标记
function ctn_mf:clear_field_dirty(field)
    self.field_dirty_[field] = nil
end

-- 检查字段是否脏
function ctn_mf:is_field_dirty(field)
    return self.field_dirty_[field] == true
end

-- 获取所有脏字段
function ctn_mf:get_dirty_fields()
    local fields = {}
    for field in pairs(self.field_dirty_) do
        table.insert(fields, field)
    end
    return fields
end

-- 合并数据
function ctn_mf:merge_data(old_data, new_data)
    if self.merge_strategy_ == MERGE_STRATEGY.REPLACE then
        return new_data
    elseif self.merge_strategy_ == MERGE_STRATEGY.KEEP_OLD then
        return old_data
    elseif self.merge_strategy_ == MERGE_STRATEGY.KEEP_NEW then
        return new_data
    elseif self.merge_strategy_ == MERGE_STRATEGY.MERGE then
        local merged = tableUtils.deep_copy(old_data)
        for k, v in pairs(new_data) do
            if type(v) == "table" and type(merged[k]) == "table" then
                merged[k] = self:merge_data(merged[k], v)
            else
                merged[k] = v
            end
        end
        return merged
    end
    return new_data
end

-- 保存数据
function ctn_mf:onsave()
    if not self:is_loaded() then
        self:set_error("Data not loaded")
        return nil, ERROR_CODE.NOT_LOADED
    end
    
    local data = {}
    for field, value in pairs(self.datas_) do
        if self:is_field_dirty(field) then
            data[field] = value
        end
    end
    
    local ok, size = self:check_data_size(data)
    if not ok then
        self:set_error(string.format("Data size %d exceeds limit %d", size, self.max_data_size_))
        return nil, ERROR_CODE.INVALID_DATA
    end
    
    return data
end

-- 加载数据
function ctn_mf:onload(_data)
    if not _data then
        return
    end
    
    for field, value in pairs(_data) do
        if self.datas_[field] then
            self.datas_[field] = self:merge_data(self.datas_[field], value)
        else
            self.datas_[field] = value
        end
    end
end

-- 从数据库加载数据
function ctn_mf:doload()
    local dbc = skynet.localname(".dbc")
    local cond = {player_id = self.prikey_}
    local ret = skynet.call(dbc, "lua", "select", self.tbl_, cond, {lba = self.prikey_})
    
    if ret.badresult then
        self:set_error("Failed to load data from database")
        return false, ERROR_CODE.DB_ERROR
    end
    
    if next(ret) then 
        for _, row in ipairs(ret) do
            local data = tableUtils.deserialize_table(row.data)
            self:onload(data)
        end
    end
    
    return true
end

-- 保存数据到数据库
function ctn_mf:save()
    if not self:is_loaded() then
        self:set_error("Data not loaded")
        return false, ERROR_CODE.NOT_LOADED
    end
    
    local data, err_code = self:onsave()
    if not data then
        return false, err_code
    end
    
    local dbc = skynet.localname(".dbc")
    local cond = {player_id = self.prikey_}
    
    local ok, err = pcall(function()
        for field, value in pairs(data) do
            local fields = {data = tableUtils.serialize_table({[field] = value})}
            local ret = skynet.call(dbc, "lua", "update", self.tbl_, cond, fields)
            if not ret then
                error(string.format("Failed to update field %s", field))
            end
            self:clear_field_dirty(field)
        end
    end)
    
    if not ok then
        self:set_error(err)
        return false, ERROR_CODE.DB_ERROR
    end
    
    self.last_save_time_ = skynet.time()
    return true
end

-- 批量添加数据
function ctn_mf:batch_add(items)
    if not self:is_loaded() then
        return false, ERROR_CODE.NOT_LOADED
    end
    
    for field, value in pairs(items) do
        self.datas_[field] = value
        self:set_field_dirty(field)
    end
    
    return true
end

-- 批量删除数据
function ctn_mf:batch_remove(fields)
    if not self:is_loaded() then
        return false, ERROR_CODE.NOT_LOADED
    end
    
    for _, field in ipairs(fields) do
        self.datas_[field] = nil
        self:set_field_dirty(field)
    end
    
    return true
end

-- 批量更新数据
function ctn_mf:batch_update(items)
    if not self:is_loaded() then
        return false, ERROR_CODE.NOT_LOADED
    end
    
    for field, value in pairs(items) do
        if self.datas_[field] then
            self.datas_[field] = self:merge_data(self.datas_[field], value)
            self:set_field_dirty(field)
        end
    end
    
    return true
end

-- 获取所有字段
function ctn_mf:get_all_fields()
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
function ctn_mf:get_all_values()
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
function ctn_mf:has_field(field)
    if not self:is_loaded() then
        return false, ERROR_CODE.NOT_LOADED
    end
    return self.datas_[field] ~= nil
end

-- 获取数据大小
function ctn_mf:get_data_size()
    if not self:is_loaded() then
        return 0, ERROR_CODE.NOT_LOADED
    end
    
    local size = #tableUtils.serialize_table(self.datas_)
    return size
end

-- 清空数据
function ctn_mf:clear()
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
function ctn_mf:get_stats()
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

return ctn_mf
