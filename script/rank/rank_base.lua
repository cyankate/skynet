local skynet = require "skynet"
local class = require "utils.class"
local log = require "log"
local tableUtils = require "utils.tableUtils"

local rank_base = class("rank_base")
--[[
    rank_base 是一个基类，用于实现排行榜的基本功能。
    它提供了加载、保存、添加数据等方法。
]]
function rank_base:ctor(_name)
    self.name_ = _name or "noname" -- 排行榜名称
    self.loaded_ = false           -- 是否已加载数据
    self.inserted_ = false         -- 是否已插入数据
    self.dirty_ = false            -- 数据是否被修改
    self.irank_ = {}               -- 榜内排行榜数据
    self.orank_ = {}               -- 榜外排行榜数据
    self.k2pos_ = {}               -- key到位置的映射
end

function rank_base:insert(_data)
    if not self.loaded_ then
        log.error(string.format("[rank_base] Data not loaded for rank: %s", self.name_))
        return false
    end
    if not _data or type(_data) ~= "table" then
        log.error(string.format("[rank_base] Invalid data for rank: %s", self.name_))
        return false
    end
    local key = self:rkey(_data)
    if not key then
        log.error(string.format("[rank_base] Invalid key for rank: %s", self.name_))
        return false
    end
    _data.__time = skynet.now()
    if self:is_realtime_update() then
        self:update_irank(_data)
    else 
        local opos = self.k2pos_[key]
        if opos then 
            local odata = self.irank_[opos]
            local dir = self:conpare_func_with_time(_data, odata)
            if dir == 0 then 
                return false
            end
        end 
        local odata = self.orank_[key]
        if odata then 
            local dir = self:conpare_func_with_time(_data, odata)
            if dir == 0 then 
                return false
            end
        end
        self.orank_[key] = _data
    end 
    return true
end

function rank_base:update_irank(_data)
    local key = self:rkey(_data)
    local opos = self.k2pos_[key]
    if opos then
        if _data.key == "name4" then 
            log.error("[rank_base] update_irank: key = name4, opos = " .. opos)
        end 
        local dir = self:compare_func(_data, self.irank_[opos])
        if dir > 0 then 
            local srank = self:slice_irank(opos, #self.irank_)
            table.remove(srank, 1)
            -- 因为compare_func_with_time函数的设计上, 目标元素和对比元素如果时间戳相同
            -- 则会把目标元素放到对比元素的后面, 但此处的目标元素本来就在对比元素的前面, 所以干脆不比较时间了
            local offset = tableUtils.binary_search(srank, _data, self.compare_func, self)
            if offset == 0 then
                return false
            end
            if _data.key == "name4" then 
                log.error("[rank_base] update_irank: key = name4, offset = " .. offset)
            end 
            local npos = opos - 1 + offset

        elseif dir < 0 then
            local srank = self:slice_irank(1, opos)
            table.remove(srank, #srank)
            -- 此处用conpare_func_with_time函数来比较, 是因为目标元素和前面位置的元素比较时
            -- 即便时间戳相同, 也应该把目标元素放到后面, 正符合这个函数的设计
            local offset = tableUtils.binary_search(srank, _data, self.conpare_func_with_time, self)
            if offset == 0 then
                return false
            end
            local npos = offset
        else 
            return false
        end 
        table.remove(self.irank_, opos)
        table.insert(self.irank_, npos, _data)
        for i = opos, npos do
            local key = self:rkey(self.irank_[i])
            if key then
                self.k2pos_[key] = i
            end
        end
        self.dirty_ = true

    else
        local dir = self:conpare_func_with_time(_data, self.irank_[#self.irank_])
        local npos
        if dir >= 0 then 
            if #self.irank_ < self:max_rank() then 
                npos = #self.irank_ + 1 
                table.insert(self.irank_, npos, _data)
            end 
        else 
            local pos = tableUtils.binary_search(self.irank_, _data, self.conpare_func_with_time, self)
            if pos == 0 then
                return false
            end
            npos = pos
            table.insert(self.irank_, npos, _data)
            if #self.irank_ > self:max_rank() then 
                table.remove(self.irank_, #self.irank_)
            end
        end
        if npos then 
            for i = npos, #self.irank_ do
                local key = self:rkey(self.irank_[i])
                if key then
                    self.k2pos_[key] = i
                end
            end
            self.dirty_ = true
        end 
    end
end 

function rank_base:rerank()
    if not self.loaded_ then
        log.error(string.format("[rank_base] Data not loaded for rank: %s", self.name_))
        return false
    end
    if #self.irank_ == 0 then
        log.error(string.format("[rank_base] No data to rerank for rank: %s", self.name_))
        return false
    end
    table.sort(self.irank_, self.conpare_func_with_time)
    for i = 1, #self.irank_ do
        local key = self:rkey(self.irank_[i])
        if key then
            self.k2pos_[key] = i
        end
    end
    return true
end

function rank_base:print()
    if not self.loaded_ then
        log.error(string.format("[rank_base] Data not loaded for rank: %s", self.name_))
        return false
    end
    log.debug(string.format("[rank_base] Rank data for %s:", self.name_))
    for i, data in ipairs(self.irank_) do
        log.debug(string.format("Rank %d: %s", i, tableUtils.serialize_table(data)))
    end
    log.debug(string.format("[rank_base] k2pos: %s", tableUtils.serialize_table(self.k2pos_)))
end

function rank_base:merge_orank()
    if not self.loaded_ then
        log.error(string.format("[rank_base] Data not loaded for rank: %s", self.name_))
        return false
    end
    if not next(self.orank_) then
        log.error(string.format("[rank_base] No data to merge for rank: %s", self.name_))
        return false
    end
    for key, data in pairs(self.orank_) do
        self:update_irank(data)
    end
end 

function rank_base:slice_irank(_start, _end)
    if not self.loaded_ then
        log.error(string.format("[rank_base] Data not loaded for rank: %s", self.name_))
        return {}
    end
    if _start < 1 or _end < 1 or _start > _end then
        log.error(string.format("[rank_base] Invalid slice range for rank: %s", self.name_))
        return {}
    end
    local result = {}
    for i = _start, math.min(_end, #self.irank_) do
        table.insert(result, self.irank_[i])
    end
    return result
end

function rank_base:max_rank()
    return 100
end 

function rank_base:conpare_func_with_time(_a, _b)
    if not _b then 
        return -1
    end
    local ret = self:compare_func(_a, _b)
    if ret == 0 then
        if _a.__time < _b.__time then
            ret = -1
        else 
            ret = 1
        end
    end
    return ret
end 

function rank_base:compare_func(_a, _b)
    log.error(string.format("[rank_base] compare_func not implemented for rank: %s", self.name_))
end

function rank_base:is_realtime_update()
    return false
end

function rank_base:rkey(_data)
    return _data.key 
end 

function rank_base:onsave()
    -- 这里可以添加保存数据的逻辑
    -- 例如将 self.datas_ 保存到数据库
    return self.datas_
end
function rank_base:onload(_datas)
    -- 这里可以添加加载数据的逻辑
    -- 例如将从数据库加载的数据赋值给 self.datas_
    self.datas_ = _datas or {}
end

function rank_base:load(_loaded_cb)
    if self.loaded_ then
        log.error(string.format("[rank_base] Data already loaded for rank: %s", self.name_))
        return
    end
    skynet.fork(function()
        self:doload()
        self.loaded_ = true
        if _loaded_cb then
            _loaded_cb(self)
        end
    end)
end

function rank_base:doload()
    local dbc = skynet.localname(".dbc")
    local cond = {name = self.name_}
    local ret = skynet.call(dbc, "lua", "select", "rank", cond)
    
    if ret and #ret > 0 then
        local data = tableUtils.unserialize_table(ret[1].data)
        self:onload(data)
        log.info(string.format("[rank_base] Rank data loaded successfully for rank: %s", self.name_))
    else
        log.error(string.format("[rank_base] Failed to load rank data for rank: %s", self.name_))
    end
end

function rank_base:save()
    if not self.loaded_ then
        log.error(string.format("[rank_base] Data not loaded for rank: %s", self.name_))
        return false
    end
    local datas = self:onsave()
    if not datas then
        log.error(string.format("[rank_base] No data to save for rank: %s", self.name_))
        return false
    end
    local dbc = skynet.localname(".dbc")
    local cond = {name = self.name_}
    local fields = {data = tableUtils.serialize_table(datas)}
    skynet.fork(function()
        if self.inserted_ then
            local ret = skynet.call(dbc, "lua", "update", "rank", cond, fields)
            if ret then
                self.dirty_ = false
                log.info(string.format("[rank_base] Rank data updated successfully for rank: %s", self.name_))
            else
                log.error(string.format("[rank_base] Failed to update rank data for rank: %s", self.name_))
            end
        else
            local ret = skynet.call(dbc, "lua", "insert", "rank", cond, fields)
            if ret and ret.insert_id then
                self.inserted_ = true
                log.info(string.format("[rank_base] Rank data inserted successfully for rank: %s", self.name_))
            else
                log.error(string.format("[rank_base] Failed to insert rank data for rank: %s", self.name_))
            end
        end
    end)
end

return rank_base
-- end