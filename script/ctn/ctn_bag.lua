local skynet = require "skynet"
local ctn_mf = require "ctn.ctn_mf"
local class = require "utils.class"
local tableUtils = require "utils.tableUtils"
local ctn_bag = class("ctn_bag", ctn_mf)
--[[
    ctn_bag 是一个背包容器类，继承自 ctn_mf 类。
    它用于存储和管理玩家的背包数据，并提供加载和保存数据的功能。
]]
function ctn_bag:ctor(_player_id, _tbl, _name)
    ctn_mf.ctor(self, _player_id, _tbl, _name)
    self.datas_ = {}
end

function ctn_bag:onsave()
    local data = {}
    for k, v in pairs(self.datas_) do
        data[k] = v
    end
    return data
end

function ctn_bag:onload(_datas)
    self.datas_ = _datas
end

return ctn_bag