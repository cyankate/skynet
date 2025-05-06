package.path = package.path .. ";./script/?.lua;./script/utils/?.lua"
local skynet = require "skynet"
local log = require "log"

local common = {}

function common.set_timeout(time, func)
    local function t()
        if func then 
            func()
        end 
    end 
    skynet.timeout(time, t)
    return function() func = nil end 
end 

return common