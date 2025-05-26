local BaseTest = require "base_test"

local PlayerTest = {}
setmetatable(PlayerTest, {__index = BaseTest})
PlayerTest.__index = PlayerTest

function PlayerTest.new(client, config, client_count)
    local self = BaseTest.new(client, config, client_count)
    setmetatable(self, PlayerTest)
    return self
end

function PlayerTest:send_random_action()
    local actions = {
        "change_name",
        "add_item",
        "add_score"
    }
    
    local action = self:random_from_list(actions)
    local args = {}
    
    if action == "change_name" then
        args.name = "Player_" .. math.random(1000, 9999)
    elseif action == "add_item" then
        args.item_id = math.random(1, 100)
        args.count = math.random(1, 10)
    elseif action == "add_score" then
        args.score = math.random(1, 1000)
    end

    return self:send_request(action, args)
end

function PlayerTest:get_test_type()
    return "player"
end

return PlayerTest 