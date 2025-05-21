local skynet = require "skynet"

local cache_item = class("cache_item")

function cache_item:ctor()

end

function cache_item:onsave()
    return {}
end 

function cache_item:onload(_data)
    
end 

function cache_item:onremove()

end 

function cache_item:onupdate()

end 

return cache_item