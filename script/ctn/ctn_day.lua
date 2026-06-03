--[[
    日周期数据容器，继承 CtnCycle。
    桶 key 由 timeutils.get_day_key 生成。
]]

local CtnCycle = require "ctn.ctn_cycle"
local class = require "utils.class"
local timeutils = require "utils.timeutils"

local CtnDay = class("CtnDay", CtnCycle)

function CtnDay:current_cycle_key()
    return timeutils.get_day_key()
end

return CtnDay
