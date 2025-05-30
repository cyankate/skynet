local BaseTest = require "base_test"

local FriendTest = {}
setmetatable(FriendTest, {__index = BaseTest})
FriendTest.__index = FriendTest

function FriendTest.new(client, config, client_count)
    local self = BaseTest.new(client, config, client_count)
    setmetatable(self, FriendTest)
    return self
end

function FriendTest:send_random_action()
    local actions = {
        "add_friend",           -- 添加好友
        "delete_friend",        -- 删除好友
        "agree_apply",          -- 同意好友申请
        "reject_apply",         -- 拒绝好友申请
        "get_friend_list",      -- 获取好友列表
        "get_apply_list",       -- 获取申请列表
        "add_blacklist",        -- 添加黑名单
        "remove_blacklist",     -- 移除黑名单
        "get_black_list"        -- 获取黑名单列表
    }
    
    local action = self:random_from_list(actions)
    local args = {}
    
    -- 随机生成目标玩家ID (10001-11000)
    local target_id = math.random(10001, 11000)
    
    if action == "add_friend" then
        args.target_id = target_id
        args.message = string.format("Hello from client %d", self.client.id)
    elseif action == "delete_friend" then
        args.target_id = target_id
    elseif action == "agree_apply" or action == "reject_apply" then
        args.player_id = target_id
    elseif action == "add_blacklist" or action == "remove_blacklist" then
        args.target_id = target_id
    elseif action == "get_friend_list" or action == "get_apply_list" or action == "get_black_list" then
        -- 这些接口不需要参数
    end

    return self:send_request(action, args)
end

function FriendTest:get_test_type()
    return "friend"
end

return FriendTest 