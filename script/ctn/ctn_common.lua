local skynet = require "skynet"
local CtnKv = require "ctn.ctn_kv"
local class = require "utils.class"
local tableUtils = require "utils.tableUtils"
local log = require "log"

--[[
    CtnCommon 是一个公共容器类，继承自 CtnKv 类。
    它用于存储和管理公共数据，并提供加载和保存数据的功能。
]]
local CtnCommon = class("CtnCommon", CtnKv)

function CtnCommon:ctor(_player_id, _tbl, _name)
    CtnKv.ctor(self, _player_id, _tbl, _name)
end

function CtnCommon:onsave()
    local data = CtnKv.onsave(self)
    return data
end

function CtnCommon:onload(data)
    CtnKv.onload(self, data)
end

return CtnCommon