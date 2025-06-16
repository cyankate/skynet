local BaseTest = require "base_test"

local MailTest = {}
setmetatable(MailTest, {__index = BaseTest})
MailTest.__index = MailTest

function MailTest.new(client, config, client_count)
    local self = BaseTest.new(client, config, client_count)
    setmetatable(self, MailTest)
    return self
end

function MailTest:send_random_action()
    local actions = {
        "get_mail_list",        -- 获取邮件列表
        "get_mail_detail",      -- 获取邮件详情
        "claim_items",          -- 领取附件
        --"delete_mail",          -- 删除邮件
        "send_player_mail",     -- 发送个人邮件
    }
    
    local action = self:random_from_list(actions)
    local args = {}
    
    if action == "get_mail_list" then
        args.page = math.random(1, 5)  -- 随机页码
        args.page_size = 10
    elseif action == "get_mail_detail" then
        -- 使用一个随机的邮件ID格式
        local sender_id = math.random(10001, 10200)
        local mail_id = string.format("p_%d_%d", sender_id, math.random(1, 100))
        args.mail_id = mail_id
    elseif action == "claim_items" then
        -- 使用一个随机的邮件ID格式
        local sender_id = math.random(10001, 10200)
        local mail_id = string.format("p_%d_%d", sender_id, math.random(1, 100))
        args.mail_id = mail_id
    elseif action == "delete_mail" then
        -- 使用一个随机的邮件ID格式
        local sender_id = math.random(10001, 10200)
        local mail_id = string.format("p_%d_%d", sender_id, math.random(1, 100))
        args.mail_id = mail_id
    elseif action == "send_player_mail" then
        args.receiver_id = math.random(10001, 10200)  -- 随机接收者ID
        args.title = string.format("Test mail from %d", self.client.id)
        args.content = string.format("This is a test mail from client %d", self.client.id)
        -- 随机决定是否添加附件
        if math.random() > 0.5 then
            args.items = {
                {item_id = math.random(1, 100), count = math.random(1, 10)}
            }
        end
    end

    return self:send_request(action, args)
end

function MailTest:get_test_type()
    return "mail"
end

return MailTest 