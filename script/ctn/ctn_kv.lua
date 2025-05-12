package.path = package.path .. ";./script/?.lua;./script/utils/?.lua"

local skynet = require "skynet"
local ctn_base = require "ctn.ctn_base"

local class = require "utils.class"
local tableUtils = require "utils.tableUtils"
local log = require "log"

local ctn_kv = class("ctn_kv", ctn_base)
--[[
    ctn_kv 是一个键值对容器类，继承自 ctn_base 类。
    它用于存储和管理键值对数据，并提供加载和保存数据的功能。
]]

-- 错误码
local ERROR_CODE = {
    SUCCESS = 0,           -- 成功
    NOT_LOADED = 1,        -- 数据未加载
    INVALID_DATA = 2,      -- 无效数据
    DB_ERROR = 3,          -- 数据库错误
    DUPLICATE_KEY = 4,     -- 重复键
    KEY_NOT_FOUND = 5,     -- 键不存在
}

function ctn_kv:ctor(_player_id, _tbl, _name)
    ctn_base.ctor(self, _player_id, _name)
    self.tbl_ = _tbl
    self.prikey_ = _player_id
    self.inserted_ = false 
    self.dirty_ = false
    self.last_save_time_ = 0
    self.auto_save_interval_ = 300
    self.max_data_size_ = 1024 * 1024 -- 最大数据大小（1MB）
end

function ctn_kv:set_dirty()
    self.dirty_ = true
end 

function ctn_kv:clear_dirty()
    self.dirty_ = false
end

function ctn_kv:is_dirty()
    return self.dirty_
end

-- 设置最大数据大小
function ctn_kv:set_max_data_size(size)
    self.max_data_size_ = size
end

-- 保存数据
function ctn_kv:onsave()
    local data = {}
    for k, v in pairs(self.data_) do
        data[k] = v
    end
    
    return data
end

-- 加载数据
function ctn_kv:onload(_data)
    if not _data then
        return
    end
    
    for k, v in pairs(_data) do
        self.data_[k] = v
    end
end

-- 从数据库加载数据
function ctn_kv:doload()
    local dbc = skynet.localname(".db")
    local cond = {player_id = self.prikey_}
    local ret = skynet.call(dbc, "lua", "select", self.tbl_, cond, {lba = self.prikey_})
    
    if ret.badresult then
        self:set_error("Failed to load data from database")
        return false, ERROR_CODE.DB_ERROR
    end
    
    self.inserted_ = true 
    if next(ret) then 
        local data = ret[1].data
        self:onload(data)
    end
    
    return true
end

-- 保存数据到数据库
function ctn_kv:dosave()
    local data, err_code = self:onsave()
    if not data then
        return false, err_code
    end
    
    local db = skynet.localname(".db")
    local cond = {player_id = self.prikey_}
    local fields = {data = data}
    for k, v in pairs(cond) do
        fields[k] = v
    end
    if not self.inserted_ then
        local ret = skynet.call(db, "lua", "insert", self.tbl_, fields)
        if ret then
            self.inserted_ = true
            self:clear_dirty()
        else
            error("Failed to insert data")
        end
    else 
        local ret = skynet.call(db, "lua", "update", self.tbl_, fields)
        if not ret then
            error("Failed to update data")
        end
    end
    self:clear_dirty()
    return true 
end

-- 批量添加数据
function ctn_kv:batch_add(items)
    if not self:is_loaded() then
        return false, ERROR_CODE.NOT_LOADED
    end
    
    for k, v in pairs(items) do
        self.data_[k] = v
    end
    
    self:set_dirty()
    return true
end

-- 批量删除数据
function ctn_kv:batch_remove(keys)
    if not self:is_loaded() then
        return false, ERROR_CODE.NOT_LOADED
    end
    
    for _, k in ipairs(keys) do
        self.data_[k] = nil
    end
    
    self:set_dirty()
    return true
end

-- 批量更新数据
function ctn_kv:batch_update(items)
    if not self:is_loaded() then
        return false, ERROR_CODE.NOT_LOADED
    end
    
    for k, v in pairs(items) do
        if self.data_[k] then
            self.data_[k] = v
        end
    end
    
    self:set_dirty()
    return true
end

-- 获取所有键
function ctn_kv:get_all_keys()
    if not self:is_loaded() then
        return nil, ERROR_CODE.NOT_LOADED
    end
    
    local keys = {}
    for k in pairs(self.data_) do
        table.insert(keys, k)
    end
    return keys
end

-- 获取所有值
function ctn_kv:get_all_values()
    if not self:is_loaded() then
        return nil, ERROR_CODE.NOT_LOADED
    end
    
    local values = {}
    for _, v in pairs(self.data_) do
        table.insert(values, v)
    end
    return values
end

-- 检查键是否存在
function ctn_kv:has_key(key)
    if not self:is_loaded() then
        return false, ERROR_CODE.NOT_LOADED
    end
    return self.data_[key] ~= nil
end

-- 获取数据大小
function ctn_kv:get_data_size()
    if not self:is_loaded() then
        return 0, ERROR_CODE.NOT_LOADED
    end
    
    local size = #tableUtils.serialize_table(self.data_)
    return size
end

-- 清空数据
function ctn_kv:clear()
    if not self:is_loaded() then
        return false, ERROR_CODE.NOT_LOADED
    end
    
    self.data_ = {}
    self:set_dirty()
    return true
end

-- 获取数据统计信息
function ctn_kv:get_stats()
    if not self:is_loaded() then
        return nil, ERROR_CODE.NOT_LOADED
    end
    
    local stats = {
        item_count = self:get_item_count(),
        data_size = self:get_data_size(),
        max_size = self.max_data_size_,
        last_save_time = self.last_save_time_,
        is_dirty = self:is_dirty(),
        is_inserted = self.inserted_,
    }
    return stats
end

return ctn_kv