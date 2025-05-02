package.path = package.path .. ";./script/?.lua;./script/?/init.lua"

local skynet = require "skynet"
local log = require "log"
local tableUtils = require "utils.tableUtils"

function on_add_item(_msg)

end 

function on_change_name(_msg)

end 

function on_signin(_msg)
    log.debug(string.format("on_signin %s", tableUtils.serialize_table(_msg)))
end 

local handle = {
    ["add_item"] = on_add_item,
    ["change_name"] = on_change_name,
    ["signin"] = on_signin,
}

return handle