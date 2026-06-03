--[[
    周周期数据容器，继承 CtnCycle。
    桶 key 由 timeutils.get_reset_week_key 生成。
]]

local CtnCycle = require "ctn.ctn_cycle"
local class = require "utils.class"
local timeutils = require "utils.timeutils"

local CtnWeek = class("CtnWeek", CtnCycle)

function CtnWeek:current_cycle_key()
    return timeutils.get_reset_week_key()
end

return CtnWeek
