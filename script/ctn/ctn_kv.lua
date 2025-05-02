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
function ctn_kv:ctor(_player_id, _tbl, _name)
    ctn_base.ctor(self, _player_id, _name)
    self.tbl_ = _tbl
    self.prikey_ = _player_id
    self.inserted_ = false 
    self.dirty_ = false
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

function ctn_kv:onsave()
    local data = {}
    return data 
end 

function ctn_kv:onload(_data)
    
end 

function ctn_kv:save()
    if not self.loaded_ then
        log.error(string.format("invalid save, Data not loaded for ctn: %s", self.owner_))
        return false
    end
    local data = self:onsave()
    if not data then
        log.error(string.format("No data to save for ctn: %s", self.prikey_))
        return false
    end
    local dbc = skynet.localname(".dbc")
    local cond = {player_id = self.prikey_}
    local fields = {data = tableUtils.serialize_table(data)}
    skynet.fork(function()
        if not self.inserted_ then
            local ret = skynet.call(dbc, "lua", "insert", self.tbl_, cond, fields)
            if ret then
                self.inserted_ = true
                self:clear_dirty()
            else
                log.error(string.format("Failed to insert data for ctn: %s", self.__cname))
            end
        else 
            local ret = skynet.call(dbc, "lua", "update", self.tbl_, cond, fields)
            if ret then 
                self:clear_dirty()
            end     
        end 
    end)
end 

function ctn_kv:doload()
    local dbc = skynet.localname(".dbc")
    local cond = {player_id = self.prikey_}
    local ret = skynet.call(dbc, "lua", "select", self.tbl_, cond, {lba = self.prikey_})
    if ret.badresult then
        log.error(string.format("Failed to load data for ctn: %s", self.__cname))
        return
    end
    self.inserted_ = true 
    if next(ret) then 
        local data = tableUtils.deserialize_table(ret[1])
        self:onload(data)
    end 
end

return ctn_kv