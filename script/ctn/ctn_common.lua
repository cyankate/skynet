local CtnKv = require "ctn.ctn_kv"
local class = require "utils.class"

local TALENTS_KEY = "talents"
local WEAPONS_KEY = "weapons"
local DEFAULT_WEAPON_LEVEL = 1

--[[
    CtnCommon 公共容器：车头/天赋/武器等养成数据。
]]
local CtnCommon = class("CtnCommon", CtnKv)

function CtnCommon:ctor(_player_id, _tbl, _name)
    CtnKv.ctor(self, _player_id, _tbl, _name)
end

function CtnCommon:onsave()
    return CtnKv.onsave(self)
end

function CtnCommon:onload(data)
    CtnKv.onload(self, data)
end

function CtnCommon:get_talents()
    local talents = self:get(TALENTS_KEY)
    if type(talents) ~= "table" then
        return {}
    end
    return talents
end

function CtnCommon:set_talent_activated(talent_id)
    talent_id = tonumber(talent_id) or 0
    if talent_id <= 0 then
        return false
    end
    local talents = self:get_talents()
    talents[talent_id] = true
    return self:set(TALENTS_KEY, talents)
end

function CtnCommon:get_weapons()
    local weapons = self:get(WEAPONS_KEY)
    if type(weapons) ~= "table" then
        return {}
    end
    return weapons
end

function CtnCommon:set_weapon_unlocked(weapon_id)
    weapon_id = tonumber(weapon_id) or 0
    if weapon_id <= 0 then
        return false
    end
    local weapons = self:get_weapons()
    if weapons[weapon_id] then
        return true
    end
    weapons[weapon_id] = { level = DEFAULT_WEAPON_LEVEL }
    return self:set(WEAPONS_KEY, weapons)
end

return CtnCommon
