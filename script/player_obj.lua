
local skynet = require "skynet"
local class = require "utils.class"
local log = require "log"
local mail_cache = require "cache.mail_cache"
local Player = class("Player")

function Player:ctor(_player_id, _player_data)
    self.player_id_ = _player_id
    self.player_name_ = _player_data.player_name
    self.account_key_ = _player_data.account_key
    self.ctns_ = {} -- 存储容器对象
    self.ctn_loading_ = {} -- 正在加载的容器
    self.loaded_ = false 
    self.mail_cache_ = nil
end

function Player:on_loaded()
    -- 这里可以添加玩家加载完成后的逻辑
    log.info(string.format("Player %s on_loaded successfully", self.player_id_))
    -- 例如通知其他服务，或者进行一些初始化操作
    self.loaded_ = true 

    self.mail_cache_ = mail_cache.new()

    local rankS = skynet.localname(".rank")
    skynet.send(rankS, "lua", "update_rank", "score", {
        player_id = self.player_id_,
        score = 100,
    })
end 

function Player:get_ctn(name)
    return self.ctns_[name]
end

function Player:save_to_db()
    for _, ctn in pairs(self.ctns_) do
        ctn:save()
    end
end

function Player:add_item(_item_id, _count)
    local ctn = self:get_ctn("bag")
    if not ctn then
        return false, "Bag not found"
    end
    ctn:add_item({
        item_id = _item_id,
        count = _count,
    })
end

function Player:change_name(_name)
    local ctn = self:get_ctn("base")
    if not ctn then
        return false, "Base not found"
    end
    ctn:set("player_name", _name)
end

function Player:get_player_name()
    local ctn = self:get_ctn("base")
    if not ctn then
        return false, "Base not found"
    end
    return ctn:get("player_name")
end 

function Player:signin()
    local ctn = self:get_ctn("base")
    if not ctn then
        return false, "Base not found"
    end
    ctn:set("signin_days", 1)
end

function Player:add_score(_score)
    local ctn = self:get_ctn("base")
    if not ctn then
        return false, "Base not found"
    end
    ctn:inc("score", _score)
end

function Player:get_score()
    local ctn = self:get_ctn("base")
    if not ctn then
        return 0
    end
    return ctn:get("score")
end

return Player