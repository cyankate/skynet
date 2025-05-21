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

function rank_base:update(_data)
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
    
    local opos = self.k2pos_[key]
    if opos then
        -- 已经在榜内，记录旧位置
        _data.__opos = opos
    else
        -- 新上榜，记录为榜外
        _data.__opos = -1
    end
    -- 记录更新时间
    _data.__time = os.time()

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
        -- 跟榜内的自己比, 就不需要对比时间了
        local dir = self:conpare_func_with_time(_data, self.irank_[opos])
        local npos
        if dir > 0 then 
            local srank = self:slice_irank(opos + 1, #self.irank_)
            if not next(srank) then
                self.irank_[opos] = _data
                return false
            end
            -- 因为compare_func_with_time函数的设计上, 目标元素和对比元素如果时间戳相同
            -- 则会把目标元素放到对比元素的后面, 但此处的目标元素本来就在对比元素的前面, 所以干脆不比较时间了
            local offset = tableUtils.binary_search(srank, _data, self.conpare_func_with_time, self)
            if offset == 0 then
                self.irank_[opos] = _data
                return false
            end
            if _data.key == "name4" then 
                log.error("[rank_base] update_irank: key = name4, offset = " .. offset)
            end 
            npos = opos - 1 + offset

        elseif dir < 0 then
            local srank = self:slice_irank(1, opos - 1)
            if not next(srank) then
                self.irank_[opos] = _data
                return false
            end
            -- 此处用conpare_func_with_time函数来比较, 是因为目标元素和前面位置的元素比较时
            -- 即便时间戳相同, 也应该把目标元素放到后面, 正符合这个函数的设计
            local offset = tableUtils.binary_search(srank, _data, self.conpare_func_with_time, self)
            if offset == 0 then
                self.irank_[opos] = _data
                return false
            end
            npos = offset
        else 
            return false
        end 
        table.remove(self.irank_, opos)
        table.insert(self.irank_, npos, _data)
        for i = math.min(opos, npos), math.max(opos, npos) do
            local key = self:rkey(self.irank_[i])
            if key then
                self.k2pos_[key] = i
                -- 更新所有受影响玩家的旧位置
                self.irank_[i].__opos = i
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
                    -- 更新所有受影响玩家的旧位置
                    self.irank_[i].__opos = i
                end
            end
            self.dirty_ = true
        end 
    end
end 

--子类重写
function rank_base:check_data(_data)
    local key = self:rkey(_data)
    if not key then
        log.error(string.format("[rank_base] Invalid key for rank: %s", self.name_))
        return false
    end
    return true
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
        -- 如果分数相同, 验证历史位置
        local a_in_rank = _a.__opos > 0
        local b_in_rank = _b.__opos > 0
        
        if a_in_rank and not b_in_rank then
            -- 已经在榜内的排在前面
            ret = -1
        elseif not a_in_rank and b_in_rank then
            -- 已经在榜内的排在前面
            ret = 1
        elseif a_in_rank and b_in_rank then
            -- 都在榜内，保持相对位置
            if _a.__opos < _b.__opos then
                ret = -1
            else
                ret = 1
            end
        else
            -- 都不在榜内，按时间排序
            if _a.__time < _b.__time then
                ret = -1
            else
                ret = 1
            end
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

--子类重写
function rank_base:rkey(_data)
    return _data.key 
end 

function rank_base:onsave()
    local data = {}
    data.name = self.name_
    data.irank = self.irank_
    return data
end
function rank_base:onload(_datas)
    self.irank_ = _datas.irank
    for i, data in ipairs(self.irank_) do
        local key = self:rkey(data)
        if key then
            self.k2pos_[key] = i
        end
    end
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
    local dbc = skynet.localname(".db")
    local cond = {name = self.name_}
    local ret = skynet.call(dbc, "lua", "select", "ranking", cond)
    
    if ret and #ret > 0 then
        local data = ret[1].data
        self:onload(data)
        self.inserted_ = true 
        log.debug(string.format("[rank_base] Rank data loaded successfully for rank: %s", self.name_))
    end
end

function rank_base:save()
    if not self.loaded_ then
        log.error(string.format("[rank_base] Data not loaded for rank: %s", self.name_))
        return false
    end
    local data = self:onsave()
    if not data then
        log.error(string.format("[rank_base] No data to save for rank: %s", self.name_))
        return false
    end
    local dbc = skynet.localname(".db")
    local values = {name = self.name_, data = data}
    skynet.fork(function()
        if self.inserted_ then
            local ret = skynet.call(dbc, "lua", "update", "ranking", values)
            if ret then
                self.dirty_ = false
            else
                log.error(string.format("[rank_base] Failed to update rank data for rank: %s", self.name_))
            end
        else
            local ret = skynet.call(dbc, "lua", "insert", "ranking", values)
            if ret and ret.insert_id then
                self.inserted_ = true
            else
                log.error(string.format("[rank_base] Failed to insert rank data for rank: %s", self.name_))
            end
        end
    end)
end

function rank_base:batch_update(_datas)
    if not self.loaded_ then
        log.error(string.format("[rank_base] Data not loaded for rank: %s", self.name_))
        return false
    end
    
    if not _datas or type(_datas) ~= "table" or #_datas == 0 then
        log.error(string.format("[rank_base] Invalid batch data for rank: %s", self.name_))
        return false
    end

    -- 1. 预处理数据，添加时间戳
    for _, data in ipairs(_datas) do
        data.__time = os.time()
    end

    -- 2. 分离已存在和新增的数据
    local existing_data = {}
    local new_data = {}
    local existing_keys = {}
    
    for _, data in ipairs(_datas) do
        local key = self:rkey(data)
        if not key then
            log.error(string.format("[rank_base] Invalid key in batch data for rank: %s", self.name_))
            goto continue
        end
        
        local opos = self.k2pos_[key]
        if opos then
            existing_data[key] = {
                data = data,
                old_pos = opos
            }
            existing_keys[key] = true
        else
            table.insert(new_data, data)
        end
        ::continue::
    end

    -- 3. 处理已存在的数据
    local updated_irank = {}
    local updated_k2pos = {}
    
    -- 3.1 复制未更新的数据
    for i, data in ipairs(self.irank_) do
        local key = self:rkey(data)
        if not existing_keys[key] then
            table.insert(updated_irank, data)
            updated_k2pos[key] = #updated_irank
        end
    end

    -- 3.2 处理更新的数据
    local updated_data = {}
    for _, info in pairs(existing_data) do
        table.insert(updated_data, info.data)
    end
    
    -- 3.3 合并新数据
    for _, data in ipairs(new_data) do
        table.insert(updated_data, data)
    end

    -- 4. 排序所有需要更新的数据
    table.sort(updated_data, function(a, b)
        return self:conpare_func_with_time(a, b) < 0
    end)

    -- 5. 合并排序后的数据
    local final_irank = {}
    local final_k2pos = {}
    
    -- 5.1 使用归并排序合并两个有序数组
    local i, j = 1, 1
    while i <= #updated_irank and j <= #updated_data do
        if self:conpare_func_with_time(updated_irank[i], updated_data[j]) < 0 then
            table.insert(final_irank, updated_irank[i])
            local key = self:rkey(updated_irank[i])
            if key then
                final_k2pos[key] = #final_irank
            end
            i = i + 1
        else
            table.insert(final_irank, updated_data[j])
            local key = self:rkey(updated_data[j])
            if key then
                final_k2pos[key] = #final_irank
            end
            j = j + 1
        end
    end

    -- 5.2 处理剩余数据
    while i <= #updated_irank do
        table.insert(final_irank, updated_irank[i])
        local key = self:rkey(updated_irank[i])
        if key then
            final_k2pos[key] = #final_irank
        end
        i = i + 1
    end

    while j <= #updated_data do
        table.insert(final_irank, updated_data[j])
        local key = self:rkey(updated_data[j])
        if key then
            final_k2pos[key] = #final_irank
        end
        j = j + 1
    end

    -- 6. 更新排行榜数据
    self.irank_ = final_irank
    self.k2pos_ = final_k2pos
    
    -- 7. 如果超过最大排名，截断数据
    if #self.irank_ > self:max_rank() then
        for i = self:max_rank() + 1, #self.irank_ do
            local key = self:rkey(self.irank_[i])
            if key then
                self.k2pos_[key] = nil
            end
        end
        for i = self:max_rank() + 1, #self.irank_ do
            table.remove(self.irank_)
        end
    end

    self.dirty_ = true
    return true
end

return rank_base-- end
