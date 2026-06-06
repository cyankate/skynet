
--[[
    随机奖励功能
]]

local tableUtils = require "utils.tableUtils"
local REWARD_DATA = require "setting.REWARD_DATA"
local log = require "log"

function get_reward(_id)
    local items = {}
    local cfgs = REWARD_DATA[_id]
    if not cfgs then
        log.error("reward_mgr: get_reward _id not found: %s", _id)
        return {}
    end 
    local rand_type = cfgs.RandType
    if rand_type == 0 then
        for  i = 1, #cfgs do
            local cfg = cfgs[i]
            if math.random(100) <= cfg.Weight then
                items[cfg.ItemId] = (items[cfg.ItemId] or 0) + cfg.Count
            end
        end 
    elseif rand_type == 1 then
        local weights = {}
        for i = 1, #cfgs do
            table.insert(weights, {i, cfgs[i].Weight})
        end 
        local idx = tableUtils.random_weight_from_list(weights)
        if idx then
            local item_id = cfgs[idx].ItemId
            local count = cfgs[idx].Count
            items[item_id] = (items[item_id] or 0) + count
        end
    end
    return items
end 