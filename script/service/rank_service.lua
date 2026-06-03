local skynet = require "skynet"
local log = require "log"
local ScoreRank = require "system.rank.score_rank"
local event_def = require "define.event_def"
local service_ctx = require "runtime.service_ctx"

local M = service_ctx.get("system.rank.rank_service", {})
M.ranks = M.ranks or {}
local ranks = M.ranks

local SAVE_INTERVAL = 180 * 100

local function load_all_ranks()
    for _, rank in pairs(ranks) do
        rank:load()
    end
end

local function save_all_ranks()
    for _, rank in pairs(ranks) do
        if rank.loaded_ and rank.dirty_ then
            rank:save()
        end
    end
end

local function handle_player_login()
end

local function handle_player_level_up()
end

local function init_rank()
    if ranks["score"] then
        return
    end
    local score_rank = ScoreRank.new("score")
    ranks["score"] = score_rank
    load_all_ranks()
end

local function start_rank_save_timer()
    local function timer_func()
        skynet.timeout(SAVE_INTERVAL, timer_func)
        save_all_ranks()
    end
    skynet.timeout(SAVE_INTERVAL, timer_func)
end

function M.init()
    if M._inited then
        return true
    end
    M._inited = true

    local eventS = skynet.localname(".event")
    if eventS then
        skynet.call(eventS, "lua", "subscribe", event_def.PLAYER.LOGIN, skynet.self())
        skynet.call(eventS, "lua", "subscribe", event_def.PLAYER.LEVEL_UP, skynet.self())
    end

    init_rank()
    start_rank_save_timer()
    return true
end

function M.update_rank(rank_name, data)
    local rank = ranks[rank_name]
    if not rank then
        log.error(string.format("Rank not found: %s", rank_name))
        return false
    end
    if not rank:check_data(data) then
        log.error(string.format("Data is not valid: %s", data))
        return false
    end
    rank:update(data)
    return true
end

function M.on_event(event_name, ...)
    if event_name == event_def.PLAYER.LOGIN then
        handle_player_login(...)
    elseif event_name == event_def.PLAYER.LEVEL_UP then
        handle_player_level_up(...)
    end
end

function M.save_ranks()
    save_all_ranks()
    return true
end

function M.shutdown()
    log.info("Rank service is shutting down, saving all data...")
    save_all_ranks()
    skynet.exit()
    return true
end

return M
