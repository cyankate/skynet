local new_socket = require "socket.core"

local BaseTest = {}
BaseTest.__index = BaseTest

function BaseTest.new(client, config, client_count)
    local self = setmetatable({}, BaseTest)
    self.client = client
    self.config = config
    self.client_count = client_count
    -- 根据客户端数量计算每个客户端的发送概率
    -- 目标RPS / (客户端数量 * 每秒尝试次数)
    self.send_probability = (config.target_rps / (client_count * 10))  -- 假设每个客户端每秒尝试10次
    self.token_bucket = {
        tokens = 1,  -- 初始令牌为1
        last_update = 0,
        capacity = 1,  -- 最大突发2个令牌
        target_rps = config.target_rps,  -- 保存总体目标RPS
        last_request = 0  -- 上次请求时间
    }
    self.last_action = nil
    return self
end

function BaseTest:update_token_bucket()
    local now = new_socket.gettime()
    local time_passed = now - self.token_bucket.last_update
    
    -- 令牌生成改用固定速率
    local new_tokens = time_passed  -- 每秒最多生成1个令牌
    
    self.token_bucket.tokens = math.min(self.token_bucket.capacity, self.token_bucket.tokens + new_tokens)
    self.token_bucket.last_update = now
    
    -- 检查是否满足最小间隔要求 (100ms)
    if now - self.token_bucket.last_request < 0.1 then
        return false
    end
    
    -- 使用计算好的发送概率
    if math.random() <= self.send_probability then
        return self.token_bucket.tokens >= 1
    end
    
    return false
end

function BaseTest:consume_token()
    if self:update_token_bucket() then
        self.token_bucket.tokens = self.token_bucket.tokens - 1
        self.token_bucket.last_request = new_socket.gettime()
        return true
    end
    return false
end

function BaseTest:send_request(action, args)
    if not self.client.connected then
        print(string.format("Client %d not connected, cannot send request", self.client.id))
        return false
    end

    if not self.client.logined then
        print(string.format("Client %d not logged in, cannot send request", self.client.id))
        return false
    end

    if not self:consume_token() then
        return false
    end

    self.client:send_request(action, args)
    self.last_action = action  -- 记录最后发送的动作
    return true
end

function BaseTest:run()
    if not self.client.connected then
        return false
    end

    if not self.client.logined then
        if self.client:try_login() then
            return true
        end
        return false
    end

    return self:send_random_action()
end

-- 子类需要实现这个方法
function BaseTest:send_random_action()
    error("send_random_action must be implemented by subclass")
end

-- 工具方法
function BaseTest:random_from_list(list)
    return list[math.random(1, #list)]
end

-- 获取测试类型
function BaseTest:get_test_type()
    error("get_test_type must be implemented by subclass")
end

-- 获取最后的请求类型
function BaseTest:get_last_action()
    return self.last_action
end

return BaseTest 