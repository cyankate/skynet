package.path = package.path .. ";./script/?.lua;./script/utils/?.lua"
local skynet = require "skynet"
local class = require "utils.class"
local log = require "log"
local Player = class("Player")

function Player:ctor(_player_id, _player_data)
    self.player_id_ = _player_id
    self.player_name_ = _player_data.player_name
    self.account_key_ = _player_data.account_key
    self.ctns_ = {} -- 存储容器对象
    self.ctn_loading_ = {} -- 正在加载的容器
    self.loaded_ = false 
end

function Player:loaded()
    -- 这里可以添加玩家加载完成后的逻辑
    log.info(string.format("Player %s loaded successfully", self.player_id_))
    -- 例如通知其他服务，或者进行一些初始化操作
    self.loaded_ = true 
end 

function Player:save_to_db()
    -- 这里可以添加保存玩家数据到数据库的逻辑
    log.info(string.format("Saving player %s data to DB", self.player_id_))
    -- 例如将玩家数据保存到数据库
    for _, ctn in pairs(self.ctns_) do
        ctn:save()
    end
end

return Player