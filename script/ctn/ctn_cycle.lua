--[[
    周期数据容器基类：按整数 cycle_key 分桶，默认保留连续 keep_count 个桶。
    子类实现 current_cycle_key() 提供当前日/周 key；偏移在 resolve_key(offset) 中计算。

    - get_field / set_field：按周期偏移读写桶内字段（offset=0 当前，-1 上一周期）
    - get_data(cycle_key) / set_data(cycle_key, data)：底层按周期 key 读写整桶
    - onsave 前自动 prune，只保留当前 key 起往前 keep_count-1 个桶
]]

local CtnKv = require "ctn.ctn_kv"
local class = require "utils.class"

local CtnCycle = class("CtnCycle", CtnKv)

local DEFAULT_KEEP_COUNT = 2

local function normalize_key_store(store)
    if not store then
        return {}
    end
    local out = {}
    for k, v in pairs(store) do
        local nk = tonumber(k)
        if nk == nil then
            nk = k
        end
        if type(v) == "table" then
            out[nk] = v
        end
    end
    return out
end

local function prune_block(store, current_key, keep_count)
    if keep_count <= 0 then
        return
    end
    local min_key = current_key - (keep_count - 1)
    for k, _ in pairs(store) do
        local nk = tonumber(k) or k
        if nk < min_key then
            store[k] = nil
        end
    end
end

function CtnCycle:ctor(_player_id, _tbl, _name)
    CtnKv.ctor(self, _player_id, _tbl, _name)
    self.cycle_data_ = {}
    self.keep_count_ = DEFAULT_KEEP_COUNT
end

--- 子类实现：当前时间对应的周期 key（调用 timeutils）
function CtnCycle:current_cycle_key()
    error("CtnCycle:current_cycle_key must be implemented by subclass")
end

--- offset=0 当前周期，-1 上一周期，n 为往前 n 个周期
function CtnCycle:resolve_key(offset)
    if offset == nil then
        offset = 0
    end
    local current = self:current_cycle_key()
    if offset == -1 then
        return current - 1
    end
    return current - offset
end

function CtnCycle:get_cycle_key(offset)
    return self:resolve_key(offset)
end

--- 取周期桶；无数据返回 nil, cycle_key（不创建）
function CtnCycle:get_bucket(offset)
    if offset == nil then
        offset = 0
    end
    local cycle_key = self:resolve_key(offset)
    local bucket = self.cycle_data_[cycle_key]
    return bucket, cycle_key
end

--- 取桶内字段；无桶或无字段返回 nil
function CtnCycle:get_field(field_key, offset)
    if offset == nil then
        offset = 0
    end
    local bucket = self:get_bucket(offset)
    if not bucket then
        return nil
    end
    return bucket[field_key]
end

--- 写桶内字段；无桶则创建
function CtnCycle:set_field(field_key, value, offset)
    if offset == nil then
        offset = 0
    end
    local cycle_key = self:resolve_key(offset)
    local bucket = self.cycle_data_[cycle_key]
    if not bucket then
        bucket = {}
    end
    bucket[field_key] = value
    self:set_data(cycle_key, bucket)
    return true
end

function CtnCycle:set_keep_count(count)
    if type(count) == "number" and count >= 1 then
        self.keep_count_ = math.floor(count)
    end
end

function CtnCycle:get_keep_count()
    return self.keep_count_
end

function CtnCycle:prune_cycle_data()
    prune_block(self.cycle_data_, self:resolve_key(0), self.keep_count_)
end

function CtnCycle:onload(data)
    self.cycle_data_ = normalize_key_store(data)
end

function CtnCycle:onsave()
    self:prune_cycle_data()
    return self.cycle_data_
end

--- 返回 data, cycle_key（cycle_key 为空则用当前周期）
function CtnCycle:get_data(cycle_key)
    if not cycle_key then
        cycle_key = self:resolve_key(0)
    end
    local bucket = self.cycle_data_[cycle_key]
    if bucket then
        return bucket, cycle_key
    end
    return {}, cycle_key
end

function CtnCycle:set_data(cycle_key, data)
    if not cycle_key then
        cycle_key = self:resolve_key(0)
    end
    self.cycle_data_[cycle_key] = data or {}
    self:set_dirty()
    return true, cycle_key
end

return CtnCycle
