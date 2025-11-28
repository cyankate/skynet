
local skynet = require "skynet"
local manager = require "skynet.manager"
local log = require "log"
local ScoreRank = require "rank.score_rank"
local event_def = require "define.event_def"
local service_wrapper = require "utils.service_wrapper"

local ranks = {}
-- 定义保存间隔，单位为0.01秒，默认每3分钟保存一次（10分钟=600秒=60000单位）
local SAVE_INTERVAL = 180 * 100

function init_rank()
    local score_rank = ScoreRank.new("score")
    ranks["score"] = score_rank

    -- local level_rank = level_rank.new("level")
    -- ranks["level"] = level_rank

    -- local power_rank = power_rank.new("power")
    -- ranks["power"] = power_rank

    -- local guild_rank = guild_rank.new("guild")
    -- ranks["guild"] = guild_rank
    
    load_all_ranks()
end 

function load_all_ranks()
    for name, rank in pairs(ranks) do
        rank:load()
    end
end

-- 定时保存排行榜数据
function save_all_ranks()
    for name, rank in pairs(ranks) do
        if rank.loaded_ and rank.dirty_ then
            rank:save()
        end
    end
end

-- 启动定时保存功能
function start_rank_save_timer()
    local function timer_func()
        skynet.timeout(SAVE_INTERVAL, timer_func)
        save_all_ranks()
    end
    
    -- 启动定时器
    skynet.timeout(SAVE_INTERVAL, timer_func)
end

function CMD.update_rank(_rank_name, _data)
    -- 这里可以添加更新排名的逻辑
    local rank = ranks[_rank_name]
    if not rank then
        log.error(string.format("Rank not found: %s", _rank_name))
        return false
    end
    if not rank:check_data(_data) then
        log.error(string.format("Data is not valid: %s", _data))
        return false
    end 
    rank:update(_data)
    return true
end

function CMD.on_event(_event_name, ...)
    if _event_name == event_def.PLAYER.LOGIN then
        -- 处理玩家登录排行榜逻辑
        handle_player_login(...)
    elseif _event_name == event_def.PLAYER.LEVEL_UP then
        -- 处理玩家升级排行榜逻辑
        handle_player_level_up(...)
    end
end

-- 添加手动保存接口，方便需要立即保存的场景使用
function CMD.save_ranks()
    save_all_ranks()
    return true
end

function handle_player_login()

end 

function handle_player_level_up()

end 

function test_rank()
    local rank = ranks["score"]
    if not rank then
        log.error("Rank not found")
        return false
    end

    -- 验证函数
    local function verify_rank()
        log.info("Verifying rank data...")
        
        -- 1. 验证排名顺序
        for i = 1, #rank.irank_ - 1 do
            local current = rank.irank_[i]
            local next = rank.irank_[i + 1]
            if rank:conpare_func_with_time(current, next) > 0 then
                log.error(string.format("Rank order error at position %d: %s(%d) > %s(%d)", 
                    i, current.key, current.score, next.key, next.score))
                return false
            end
        end

        -- 2. 验证k2pos映射
        for i, data in ipairs(rank.irank_) do
            local key = rank:rkey(data)
            if rank.k2pos_[key] ~= i then
                log.error(string.format("Position mapping error for %s: expected %d, got %d", 
                    key, i, rank.k2pos_[key]))
                return false
            end
        end

        -- 3. 验证__old_pos的正确性
        for i, data in ipairs(rank.irank_) do
            if data.__opos ~= i then
                log.error(string.format("Old position error for %s: expected %d, got %d", 
                    data.key, i, data.__opos))
                return false
            end
        end

        return true
    end

    -- 打印排行榜状态
    local function print_rank_status(scenario_name)
        log.info(string.format("=== Rank Status after %s ===", scenario_name))
        for pos, data in ipairs(rank.irank_) do
            log.info(string.format("Rank %d: %s (score: %d, old_pos: %d)", 
                pos, data.key, data.score, data.__opos))
        end
    end

    -- 测试场景
    local test_scenarios = {
        -- 场景1: 初始数据，不同分数
        function()
            log.info("Scenario 1: Initial data with different scores")
            local players = {
                {key = "player1", score = 100},
                {key = "player2", score = 200},
                {key = "player3", score = 300},
                {key = "player4", score = 400},
                {key = "player5", score = 500}
            }
            for _, player in ipairs(players) do
                rank:update(player)
            end
            return "Initial data"
        end,

        -- 场景2: 同分玩家同时首次上榜
        function()
            log.info("Scenario 2: Same score players first time on rank")
            local players = {
                {key = "player6", score = 250},
                {key = "player7", score = 250}
            }
            for _, player in ipairs(players) do
                rank:update(player)
            end
            return "Same score first time"
        end,

        -- 场景3: 已在榜内的玩家分数变化
        function()
            log.info("Scenario 3: Existing player score change")
            local player = {key = "player3", score = 450}  -- 从300升到450
            rank:update(player)
            return "Score increase"
        end,

        -- 场景4: 已在榜内的玩家分数下降到与其他人相同
        function()
            log.info("Scenario 4: Existing player score decrease to same as others")
            local player = {key = "player3", score = 250}  -- 从450降到250
            rank:update(player)
            return "Score decrease to same"
        end,

        -- 场景5: 新玩家分数与榜内玩家相同
        function()
            log.info("Scenario 5: New player with same score as existing")
            local player = {key = "player8", score = 250}
            rank:update(player)
            return "New player same score"
        end,

        -- 场景6: 榜内玩家分数变化导致位置交换
        function()
            log.info("Scenario 6: Score change causing position swap")
            local player = {key = "player2", score = 350}  -- 从200升到350
            rank:update(player)
            return "Position swap"
        end,

        -- 场景7: 多个玩家同时更新
        function()
            log.info("Scenario 7: Multiple players update simultaneously")
            local players = {
                {key = "player1", score = 150},  -- 从100升到150
                {key = "player4", score = 350},  -- 从400降到350
                {key = "player9", score = 250}   -- 新玩家
            }
            for _, player in ipairs(players) do
                rank:update(player)
            end
            return "Multiple updates"
        end,

        -- 场景8: 分数相同但位置不同的玩家更新
        function()
            log.info("Scenario 8: Same score different position updates")
            local players = {
                {key = "player3", score = 250},  -- 已在榜内
                {key = "player6", score = 250},  -- 已在榜内
                {key = "player10", score = 250}  -- 新玩家
            }
            for _, player in ipairs(players) do
                rank:update(player)
            end
            return "Same score position test"
        end,

        -- 场景9: 分数变化导致位置大幅变动
        function()
            log.info("Scenario 9: Large position change")
            local player = {key = "player5", score = 100}  -- 从500降到100
            rank:update(player)
            return "Large position change"
        end,

        -- 场景10: 边界情况测试
        function()
            log.info("Scenario 10: Edge cases")
            local players = {
                {key = "player11", score = 600},  -- 超过最高分
                {key = "player12", score = 50},   -- 低于最低分
                {key = "player13", score = 250}   -- 与多个玩家同分
            }
            for _, player in ipairs(players) do
                rank:update(player)
            end
            return "Edge cases"
        end
    }

    -- 执行测试
    log.info("Starting rank test...")
    
    for i, scenario in ipairs(test_scenarios) do
        log.info(string.format("Executing test scenario %d", i))
        local scenario_name = scenario()
        
        if not verify_rank() then
            log.error(string.format("Test scenario %d verification failed", i))
            return false
        end
        
        print_rank_status(scenario_name)
        skynet.sleep(10) -- 等待更新完成
    end

    log.info("All test scenarios passed")
    return true
end

function CMD.shutdown()
    log.info("Rank service is shutting down, saving all data...")
    save_all_ranks()
    skynet.exit()
    return true
end

local function main()
    local eventS = skynet.localname(".event")
    -- 监听玩家登录事件
    skynet.call(eventS, "lua", "subscribe", event_def.PLAYER.LOGIN, skynet.self())
    -- 监听玩家升级事件
    skynet.call(eventS, "lua", "subscribe", event_def.PLAYER.LEVEL_UP, skynet.self())
    
    init_rank()
    
    -- 启动定时保存功能
    start_rank_save_timer()
end

service_wrapper.create_service(main, {
    name = "rank",
})