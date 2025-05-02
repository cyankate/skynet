package.path = package.path .. ";./script/?.lua;./script/utils/?.lua"
local skynet = require "skynet"
local ctn_base = require "ctn.ctn_base"
local class = require "utils.class"

local tableUtils = require "utils.tableUtils"

local ctn_mf = class("ctn_mf", ctn_base)

function ctn_mf:ctor(_player_id, _tbl, _name)
    ctn_base.ctor(self, _player_id, _name)
    self.tbl_ = _tbl
    self.prikey_ = _player_id
    self.field_dirty_ = {}
    self.dbexist_ = {}
    self.datas_ = {}
end

function ctn_mf:onsave()
    return self.datas_
end 

function ctn_mf:onload(_datas)
    self.datas_ = _datas
end 

function ctn_mf:save()
    local datas = self:onsave()
    if not datas then
        log.error(string.format("[ctn_mf] No data to save for ctn: %s", self.owner_))
        return false
    end
    skynet.fork(function()
        local dbc = skynet.localname(".dbc")
        for k, v in pairs(datas) do
            if self.field_dirty_[k] then
                local cond = {player_id = self.prikey_, idx = k}
                local fields = {data = tableUtils.serialize_table(v)}
                if self.dbexist_[k] then 
                    local ret = skynet.call(dbc, "lua", "update", self.tbl_, cond, fields)
                    if ret then
                        self.field_dirty_[k] = false
                    else
                        log.error(string.format("[ctn_mf] Failed to save field %s for ctn: %s", k, self.owner_))
                    end
                else 
                    local ret = skynet.call(dbc, "lua", "insert", self.tbl_, cond, fields)
                    if ret.insert_id then 
                        self.field_dirty_[k] = false 
                    else 
                        log.error(string.format("[ctn_mf] Failed to insert field %s for ctn: %s", k, self.owner_))
                    end 
                end 
            end
        end
    end )

end 

function ctn_mf:doload()
    local dbc = skynet.localname(".dbc")
    local cond = {player_id = self.prikey_}
    local ret = skynet.call(dbc, "lua", "select", self.tbl_, cond, {lba = self.prikey_})
    if ret then
        local datas = {}
        for k, v in pairs(ret) do
            local data = tableUtils.deserialize_table(v.data)
            datas[k] = data
            self.dbexist_[k] = true
        end
        self:onload(datas)
    else
        log.error(string.format("[ctn_mf] Failed to load data for ctn: %s", self.owner_))
    end
end 

return ctn_mf
