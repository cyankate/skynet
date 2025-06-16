local skynet = require "skynet"
local cache_item = require "cache.cache_item"

local player_cache_item = class("player_cache_item", cache_item)

function player_cache_item:ctor(player_id)
    cache_item.ctor(self, player_id)
    self.player_id = player_id
    self.name = ""           -- 玩家名称
    self.level = 1           -- 玩家等级
    self.avatar = ""         -- 头像
    self.online = false      -- 是否在线
    self.last_login_time = 0 -- 最后登录时间
    self.vip_level = 0       -- VIP等级
    self.signature = ""      -- 个性签名
end

function player_cache_item:onsave()
    local data = {
        player_id = self.player_id,
        name = self.name,
        level = self.level,
        avatar = self.avatar,
        online = self.online,
        last_login_time = self.last_login_time,
        vip_level = self.vip_level,
        signature = self.signature
    }
    return data
end

function player_cache_item:onload(data)
    self.player_id = data.player_id
    self.name = data.name or ""
    self.level = data.level or 1
    self.avatar = data.avatar or ""
    self.online = data.online or false
    self.last_login_time = data.last_login_time or 0
    self.vip_level = data.vip_level or 0
    self.signature = data.signature or ""
end

-- 更新玩家信息
function player_cache_item:update_info(info)
    if info.name then self.name = info.name end
    if info.level then self.level = info.level end
    if info.avatar then self.avatar = info.avatar end
    if info.online ~= nil then self.online = info.online end
    if info.last_login_time then self.last_login_time = info.last_login_time end
    if info.vip_level then self.vip_level = info.vip_level end
    if info.signature then self.signature = info.signature end
end

-- 获取玩家信息
function player_cache_item:get_info()
    return {
        player_id = self.player_id,
        name = self.name,
        level = self.level,
        avatar = self.avatar,
        online = self.online,
        last_login_time = self.last_login_time,
        vip_level = self.vip_level,
        signature = self.signature
    }
end

return player_cache_item 