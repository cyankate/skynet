local BaseTest = require "base_test"

local ChatTest = {}
setmetatable(ChatTest, {__index = BaseTest})
ChatTest.__index = ChatTest

function ChatTest.new(client, config, client_count)
    local self = BaseTest.new(client, config, client_count)
    setmetatable(self, ChatTest)
    return self
end

function ChatTest:send_random_action()
    local actions = {
        "send_private_message",
        "get_channel_history",
        "get_private_history"
    }
    
    local action = self:random_from_list(actions)
    local args = {}
    if action == "send_private_message" then
        args.to_player_id = math.random(10001, 11000) -- 模拟随机目标玩家ID
        args.content = "Private message from client " .. self.client.id
    elseif action == "get_channel_history" then
        args.channel_id = 1
        args.count = 10
    elseif action == "get_private_history" then
        args.player_id = math.random(10001, 11000) -- 模拟随机玩家ID
        args.count = 10
    end

    return self:send_request(action, args)
end

function ChatTest:get_test_type()
    return "chat"
end

return ChatTest 