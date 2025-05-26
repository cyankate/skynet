local json = require "cjson"

local Stats = {}
Stats.__index = Stats

function Stats.new()
    local self = setmetatable({}, Stats)
    self.total_requests = 0
    self.start_time = os.clock()
    self.end_time = 0
    self.test_types = {}  -- 不同测试类型的统计
    return self
end

function Stats:register_test_type(test_type, config)
    self.test_types[test_type] = {
        config = config,
        requests_sent = 0,
        current_rps = 0,
        last_rps_time = os.clock(),
        last_rps_count = 0,
        request_types = {}  -- 记录每种请求类型的数量
    }
end

-- 记录发送的请求
function Stats:record_request(test_type, request_name)
    self.total_requests = self.total_requests + 1
    
    local test_stats = self.test_types[test_type]
    if test_stats then
        test_stats.requests_sent = test_stats.requests_sent + 1
        test_stats.request_types[request_name] = (test_stats.request_types[request_name] or 0) + 1
        
        -- 更新当前RPS
        local now = os.clock()
        local time_passed = now - test_stats.last_rps_time
        if time_passed >= 1.0 then
            test_stats.current_rps = (test_stats.requests_sent - test_stats.last_rps_count) / time_passed
            test_stats.last_rps_time = now
            test_stats.last_rps_count = test_stats.requests_sent
        end
    end
end

function Stats:print_report()
    local duration = os.clock() - self.start_time
    
    print("\n=== Performance Report ===")
    print(string.format("Duration: %.3f seconds", duration))
    print(string.format("Total requests sent: %d", self.total_requests))
    print(string.format("Overall RPS: %.2f", self.total_requests / duration))
    
    -- 打印各测试类型的统计信息
    for test_type, stats in pairs(self.test_types) do
        print(string.format("\n=== %s Stats ===", test_type:upper()))
        print(string.format("Target RPS: %d", stats.config.target_rps))
        print(string.format("Requests sent: %d", stats.requests_sent))
        print(string.format("Current RPS: %.2f", stats.current_rps))
        print(string.format("Average RPS: %.2f", stats.requests_sent / duration))
        
        -- 打印请求类型分布
        print("\nRequest types:")
        for name, count in pairs(stats.request_types) do
            print(string.format("  %s: %d (%.1f%%)", 
                name, 
                count, 
                count * 100 / stats.requests_sent
            ))
        end
    end
    
    print("=========================\n")
end

function Stats:save_results(config)
    local result = {
        config = config,
        stats = {
            total_requests = self.total_requests,
            duration = self.end_time - self.start_time,
            test_types = self.test_types
        }
    }
    
    local file = io.open("stress_test_results.json", "w")
    if file then
        file:write(json.encode(result))
        file:close()
        print("Results saved to stress_test_results.json")
    else
        print("Failed to save results")
    end
end

return Stats 