local skynet = require "skynet"
local CacheItem = require "cache.cache_item"

local PlayerCacheItem = class("PlayerCacheItem", CacheItem)

function PlayerCacheItem:ctor(player_id)
    CacheItem.ctor(self, player_id)
    self.player_id = player_id
    self.name = ""           -- 玩家名称
    self.level = 1           -- 玩家等级
    self.avatar = ""         -- 头像
    self.online = false      -- 是否在线
    self.last_login_time = 0 -- 最后登录时间
end

function PlayerCacheItem:onsave()
    local data = {
        player_id = self.player_id,
        name = self.name,
        level = self.level,
        avatar = self.avatar,
        online = self.online,
        last_login_time = self.last_login_time,
    }
    return data
end

function PlayerCacheItem:onload(data)
    self.player_id = data.player_id
    self.name = data.name or ""
    self.level = data.level or 1
    self.avatar = data.avatar or ""
    self.online = data.online or false
    self.last_login_time = data.last_login_time or 0
end

-- 更新玩家信息
function PlayerCacheItem:update_info(info)
    if info.name then self.name = info.name end
    if info.level then self.level = info.level end
    if info.avatar then self.avatar = info.avatar end
    if info.online ~= nil then self.online = info.online end
    if info.last_login_time then self.last_login_time = info.last_login_time end
end

-- 获取玩家信息
function PlayerCacheItem:get_info()
    return {
        player_id = self.player_id,
        name = self.name,
        level = self.level,
        avatar = self.avatar,
        online = self.online,
        last_login_time = self.last_login_time,
    }
end

return PlayerCacheItem 