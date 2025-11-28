local skynet = require "skynet"

local CacheItem = class("CacheItem")

function CacheItem:ctor(_key)
    self.key = _key
end

function CacheItem:get_key()
    return self.key
end 

function CacheItem:onsave()
    return {}
end 

function CacheItem:onload(_data)
    
end

function CacheItem:onremove()

end 

function CacheItem:onupdate()

end 

return CacheItem