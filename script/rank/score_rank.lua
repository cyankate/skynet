local skynet = require "skynet"
local log = require "log"
local class = require "utils.class"
local tableUtils = require "utils.tableUtils"

local rank_base = require "rank.rank_base"

local score_rank = class("rank", rank_base)

function score_rank:ctor(_name)
    rank_base.ctor(self, _name)

end

function score_rank:compare_func(_data1, _data2)
    if not _data1 or not _data2 then
        return 0
    end
    local score1 = _data1.score or 0
    local score2 = _data2.score or 0

    if score1 > score2 then
        return -1
    elseif score1 < score2 then
        return 1
    else
        return 0
    end
end

function score_rank:rkey(_data)
    if not _data or type(_data) ~= "table" then
        return nil
    end
    local key = _data.player_id
    if not key then
        return nil
    end
    return key
end

function score_rank:check_data(_data)
    if not _data or type(_data) ~= "table" then
        return false
    end
    if not _data.player_id then
        return false
    end 
    if not _data.score then
        return false
    end
    return true
end 


function score_rank:is_realtime_update()
    return true
end

return score_rank