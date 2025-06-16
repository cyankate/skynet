local skynet = require "skynet"
local log = require "log"
local season_def = require "define.season_def"
--local season_config = require "config.season_config"

local season = {}

-- 当前赛季数据
local current_season = nil
local current_stage = nil
local stage_timer = nil

-- 初始化赛季数据
local function init_season()
    -- 从数据库加载当前赛季数据
    local ok, season_data = pcall(function()
        return skynet.call("dbS", "lua", "load_current_season")
    end)
    
    if ok and season_data then
        current_season = season_data
        current_stage = season_data.current_stage
    else
        -- 创建新赛季
        create_new_season()
    end
    
    -- 启动赛季计时器
    start_season_timer()
end

-- 创建新赛季
local function create_new_season()
    local season_id = season_config.current_season_id
    local season_cfg = season_config.seasons[season_id]
    
    current_season = {
        id = season_id,
        state = season_def.STATE.NOT_STARTED,
        current_stage = 1,
        start_time = os.time(),
        end_time = os.time() + season_cfg.stages[1].duration,
    }
    
    -- 保存到数据库
    pcall(function()
        skynet.call("dbS", "lua", "save_current_season", current_season)
    end)
    
    -- 触发赛季开始事件
    trigger_event(season_def.EVENT.SEASON_START, current_season)
end

-- 启动赛季计时器
local function start_season_timer()
    if stage_timer then
        skynet.kill(stage_timer)
    end
    
    -- 计算下次阶段切换时间
    local next_time = current_season.end_time - os.time()
    if next_time <= 0 then
        end_season()
        return
    end
    
    -- 创建定时器
    stage_timer = skynet.timeout(next_time * 100, function()
        on_stage_timeout()
    end)
end

-- 阶段超时处理
local function on_stage_timeout()
    local season_cfg = season_config.seasons[current_season.id]
    local current_stage_cfg = season_cfg.stages[current_stage]
    
    -- 触发阶段结束事件
    trigger_event(season_def.EVENT.STAGE_END, {
        season_id = current_season.id,
        stage_id = current_stage,
    })
    
    -- 检查是否还有下一个阶段
    if current_stage < #season_cfg.stages then
        -- 切换到下一个阶段
        current_stage = current_stage + 1
        local next_stage_cfg = season_cfg.stages[current_stage]
        
        -- 更新赛季数据
        current_season.current_stage = current_stage
        current_season.end_time = os.time() + next_stage_cfg.duration
        
        -- 保存到数据库
        pcall(function()
            skynet.call("dbS", "lua", "update_season_stage", current_season)
        end)
        
        -- 触发阶段切换事件
        trigger_event(season_def.EVENT.STAGE_CHANGE, {
            season_id = current_season.id,
            stage_id = current_stage,
        })
        
        -- 重新启动计时器
        start_season_timer()
    else
        -- 赛季结束
        end_season()
    end
end

-- 结束赛季
local function end_season()
    current_season.state = season_def.STATE.ENDED
    
    -- 保存到数据库
    pcall(function()
        skynet.call("dbS", "lua", "update_season_state", current_season)
    end)
    
    -- 触发赛季结束事件
    trigger_event(season_def.EVENT.SEASON_END, current_season)
    
    -- 清理计时器
    if stage_timer then
        skynet.kill(stage_timer)
        stage_timer = nil
    end
end

-- 触发事件
local function trigger_event(event_name, ...)
    local eventS = skynet.uniqueservice("event")
    skynet.call(eventS, "lua", "trigger", event_name, ...)
end

-- 服务接口
function season.get_current_season()
    return current_season
end

function season.get_current_stage()
    return current_stage
end

local function main()
    -- 初始化赛季
    init_season()
end

service_wrapper.create_service(main, {
    name = "season",
})

return season
