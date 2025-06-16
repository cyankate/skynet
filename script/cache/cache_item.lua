local skynet = require "skynet"

local cache_item = class("cache_item")

function cache_item:ctor(_key)
    self.key = _key
end

function cache_item:get_key()
    return self.key
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