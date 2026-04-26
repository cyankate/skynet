local skynet = require "skynet"
local service_ctx = require "runtime.service_ctx"
local season_def = require "define.season_def"

local M = service_ctx.get("season.season_service", {})
M.current_season = M.current_season or nil
M.current_stage = M.current_stage or nil
M.stage_timer = M.stage_timer or nil
M._inited = M._inited or false

local function trigger_event(event_name, ...)
    local eventS = skynet.uniqueservice("event")
    skynet.call(eventS, "lua", "trigger", event_name, ...)
end

local function end_season()
    if not M.current_season then return end
    M.current_season.state = season_def.STATE.ENDED
    pcall(function() skynet.call("dbS", "lua", "update_season_state", M.current_season) end)
    trigger_event(season_def.EVENT.SEASON_END, M.current_season)
    if M.stage_timer then skynet.kill(M.stage_timer) M.stage_timer = nil end
end

local function on_stage_timeout()
    local season_config = require "define.season_config"
    local season_cfg = season_config.seasons[M.current_season.id]
    if M.current_stage < #season_cfg.stages then
        M.current_stage = M.current_stage + 1
        local next_stage_cfg = season_cfg.stages[M.current_stage]
        M.current_season.current_stage = M.current_stage
        M.current_season.end_time = os.time() + next_stage_cfg.duration
        pcall(function() skynet.call("dbS", "lua", "update_season_stage", M.current_season) end)
        trigger_event(season_def.EVENT.STAGE_CHANGE, { season_id = M.current_season.id, stage_id = M.current_stage })
        M.start_season_timer()
    else
        end_season()
    end
end

function M.start_season_timer()
    if M.stage_timer then skynet.kill(M.stage_timer) end
    local next_time = M.current_season.end_time - os.time()
    if next_time <= 0 then end_season() return end
    M.stage_timer = skynet.timeout(next_time * 100, on_stage_timeout)
end

local function create_new_season()
    local season_config = require "define.season_config"
    local season_id = season_config.current_season_id
    local season_cfg = season_config.seasons[season_id]
    M.current_season = {
        id = season_id,
        state = season_def.STATE.NOT_STARTED,
        current_stage = 1,
        start_time = os.time(),
        end_time = os.time() + season_cfg.stages[1].duration,
    }
    M.current_stage = 1
    pcall(function() skynet.call("dbS", "lua", "save_current_season", M.current_season) end)
    trigger_event(season_def.EVENT.SEASON_START, M.current_season)
end

function M.init()
    if M._inited then return end
    M._inited = true
    local ok, season_data = pcall(function() return skynet.call("dbS", "lua", "load_current_season") end)
    if ok and season_data then
        M.current_season = season_data
        M.current_stage = season_data.current_stage
    else
        create_new_season()
    end
    M.start_season_timer()
end

function M.get_current_season() return M.current_season end
function M.get_current_stage() return M.current_stage end

return M
