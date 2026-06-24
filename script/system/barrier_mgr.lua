--[[
    主线关卡：进度记录、体力校验、结算计算、星级宝箱。
]]

local protocol_handler = require "protocol_handler"
local BARRIER_DATA = require "setting.BARRIER_DATA"
local BARRIER_DEF = require "define.barrier_def"
local recovery_mgr = require "system.recovery_mgr"
local item_mgr = require "system.item_mgr"
local weapon_mgr = require "system.weapon_mgr"
local condition_mgr = require "system.condition_mgr"
local ROGUE_DEF = require "instance.rogue.rogue_def"

local M = {}

local STAMINA_ID = BARRIER_DEF.STAMINA_RECOVERY_ID
local STAMINA_COST = BARRIER_DEF.STAMINA_COST
local MAX_STARS = BARRIER_DEF.MAX_STARS

local RECORDS_KEY = "barrier_records"
local LEGACY_SESSION_KEY = "barrier_session"

local CHEST_FIELDS = {
    [1] = "RewardBox1",
    [2] = "RewardBox2",
    [3] = "RewardBox3",
}

local function num(v)
    return tonumber(v) or 0
end

local function get_ctn(player)
    return player and player:get_ctn("common")
end

function M.get_cfg(barrier_id)
    return BARRIER_DATA[num(barrier_id)]
end

local function load_records(ctn)
    local records = ctn:get(RECORDS_KEY)
    if type(records) ~= "table" then
        records = {}
    end
    return records
end

local function save_records(ctn, records)
    return ctn:set(RECORDS_KEY, records)
end

local function get_record(ctn, barrier_id)
    local records = load_records(ctn)
    local record = records[num(barrier_id)]
    if type(record) ~= "table" then
        record = {
            passed = false,
            best_stars = 0,
            claimed_chests = {},
        }
    end
    if type(record.claimed_chests) ~= "table" then
        record.claimed_chests = {}
    end
    return record, records
end

local function write_record(ctn, barrier_id, record, records)
    records[num(barrier_id)] = record
    save_records(ctn, records)
end

function M.get_record(player, barrier_id)
    local ctn = get_ctn(player)
    if not ctn then
        return nil
    end
    return get_record(ctn, barrier_id)
end

function M.is_barrier_passed(player, barrier_id)
    local record = M.get_record(player, barrier_id)
    return record and record.passed or false
end

function M.can_enter_barrier(player, barrier_id)
    barrier_id = num(barrier_id)
    local cfg = M.get_cfg(barrier_id)
    if not cfg then
        return false, "关卡配置不存在"
    end
    if barrier_id > BARRIER_DEF.MIN_BARRIER_ID then
        if not M.is_barrier_passed(player, barrier_id - 1) then
            return false, "请先通关上一关"
        end
    end
    local stamina = recovery_mgr.get_count(player, STAMINA_ID)
    if stamina == nil then
        return false, "体力数据未就绪"
    end
    if stamina < STAMINA_COST then
        return false, "体力不足"
    end
    local session = player:get_instance_session()
    if type(session) == "table" and session.inst_id then
        return false, "已有进行中的副本"
    end
    return true
end

local function scale_items(items, ratio)
    ratio = num(ratio)
    if ratio <= 0 or type(items) ~= "table" then
        return {}
    end
    local scaled = {}
    for item_id, count in pairs(items) do
        local n = math.floor(num(count) * ratio)
        if n > 0 then
            scaled[num(item_id)] = n
        end
    end
    return scaled
end

local function merge_items(dst, src)
    for item_id, count in pairs(src or {}) do
        local id = num(item_id)
        if id > 0 and count > 0 then
            dst[id] = num(dst[id]) + num(count)
        end
    end
    return dst
end

local function build_weapon_levels(player, weapon_ids)
    local levels = {}
    for _, weapon_id in ipairs(weapon_ids or {}) do
        weapon_id = num(weapon_id)
        if weapon_id > 0 then
            levels[weapon_id] = weapon_mgr.get_weapon_level(player, weapon_id)
        end
    end
    return levels
end

function M.build_rogue_join_data(player, inst_no, cfg)
    inst_no = num(inst_no)
    cfg = cfg or M.get_cfg(inst_no) or {}
    local unlocked_weapon_ids = weapon_mgr.get_unlocked_weapon_ids(player)
    return {
        inst_no = inst_no,
        rogue_refresh_id = num(cfg.RogueRefreshId) > 0 and num(cfg.RogueRefreshId) or ROGUE_DEF.DEFAULT_REFRESH_ID,
        energy_needs = type(cfg.EnergyNeed) == "table" and cfg.EnergyNeed or ROGUE_DEF.DEFAULT_ENERGY_NEEDS,
        lineup_weapon_ids = unlocked_weapon_ids,
        unlocked_weapon_ids = unlocked_weapon_ids,
        weapon_levels = build_weapon_levels(player, unlocked_weapon_ids),
    }
end

function M.normalize_stars(stars, success)
    stars = num(stars)
    if stars < 0 then
        stars = 0
    end
    if stars > MAX_STARS then
        stars = MAX_STARS
    end
    if success and stars <= 0 then
        stars = 1
    end
    return stars
end

function M.normalize_progress(progress)
    progress = num(progress)
    if progress < 0 then
        progress = 0
    end
    if progress > 100 then
        progress = 100
    end
    return progress
end

function M.calc_settle(player, inst_no, success, stars, progress)
    local ctn = get_ctn(player)
    if not ctn then
        return false, "common container not found"
    end

    inst_no = num(inst_no)
    local cfg = M.get_cfg(inst_no)
    if not cfg then
        return false, "关卡配置不存在"
    end

    stars = M.normalize_stars(stars, success)
    progress = M.normalize_progress(progress)

    local record, records = get_record(ctn, inst_no)
    local first_pass = not record.passed
    local reward_items = {}

    if progress > 0 and cfg.ProgressReward then
        merge_items(reward_items, scale_items(cfg.ProgressReward, progress / 100))
    end

    if success then
        record.passed = true
        if stars > num(record.best_stars) then
            record.best_stars = stars
        end
        if cfg.PassReward then
            merge_items(reward_items, cfg.PassReward)
        end
    end

    write_record(ctn, inst_no, record, records)

    return true, {
        rewards = reward_items,
        settle_extra = {
            inst_no = inst_no,
            success = success,
            stars = stars,
            progress = progress,
            best_stars = record.best_stars,
            first_pass = first_pass,
        },
    }
end

function M.can_claim_chest(player, barrier_id, chest_index)
    chest_index = num(chest_index)
    if chest_index < 1 or chest_index > MAX_STARS then
        return false, "宝箱档位无效"
    end
    local cfg = M.get_cfg(barrier_id)
    if not cfg then
        return false, "关卡配置不存在"
    end
    local record = M.get_record(player, barrier_id)
    if not record or not record.passed then
        return false, "关卡未通关"
    end
    if num(record.best_stars) < chest_index then
        return false, "星级不足"
    end
    if record.claimed_chests[chest_index] then
        return false, "宝箱已领取"
    end
    local field = CHEST_FIELDS[chest_index]
    if not field or not cfg[field] then
        return false, "宝箱奖励未配置"
    end
    return true, cfg[field]
end

function M.claim_chest(player, barrier_id, chest_index)
    barrier_id = num(barrier_id)
    chest_index = num(chest_index)
    local ok, result = M.can_claim_chest(player, barrier_id, chest_index)
    if not ok then
        return false, result
    end

    local ctn = get_ctn(player)
    local record, records = get_record(ctn, barrier_id)
    record.claimed_chests[chest_index] = true
    write_record(ctn, barrier_id, record, records)

    local add_ok, add_err = item_mgr.add_items(player, result, "barrier_chest")
    if not add_ok then
        record.claimed_chests[chest_index] = nil
        write_record(ctn, barrier_id, record, records)
        return false, add_err or "发放奖励失败"
    end

    return true, {
        barrier_id = barrier_id,
        chest_index = chest_index,
        rewards = result,
    }
end

function M.build_sync_list(player)
    local list = {}
    for barrier_id, cfg in pairs(BARRIER_DATA) do
        barrier_id = num(barrier_id)
        local record = M.get_record(player, barrier_id) or {}
        local claimed = {}
        for idx, _ in pairs(record.claimed_chests or {}) do
            claimed[#claimed + 1] = num(idx)
        end
        table.sort(claimed)
        local unlocked = barrier_id == BARRIER_DEF.MIN_BARRIER_ID
            or M.is_barrier_passed(player, barrier_id - 1)
        list[#list + 1] = {
            barrier_id = barrier_id,
            name = cfg.Name,
            unlocked = unlocked,
            passed = record.passed and true or false,
            best_stars = num(record.best_stars),
            claimed_chests = claimed,
        }
    end
    table.sort(list, function(a, b)
        return a.barrier_id < b.barrier_id
    end)
    return list
end

function M.sync_to_client(player)
    if not player or not player.player_id_ then
        return false
    end
    local stamina = recovery_mgr.get_count(player, STAMINA_ID) or 0
    protocol_handler.send_to_player(player.player_id_, "barrier_info_notify", {
        stamina = stamina,
        barriers = M.build_sync_list(player),
    })
    return true
end

local function cleanup_legacy_session(player)
    local ctn = get_ctn(player)
    if ctn and ctn:get(LEGACY_SESSION_KEY) ~= nil then
        ctn:set(LEGACY_SESSION_KEY, nil)
    end
    if player then
        player:clear_instance_session()
    end
end

function M.init_player(player)
    local ctn = get_ctn(player)
    if not ctn then
        return false
    end
    if ctn:get(RECORDS_KEY) == nil then
        ctn:set(RECORDS_KEY, {})
    end
    cleanup_legacy_session(player)
    return true
end

function M.on_player_loaded(player)
    cleanup_legacy_session(player)
    return true
end

function M.clear_session(player)
    if player then
        player:clear_instance_session()
    end
end

function M.before_instance_start(player, ctx)
    local inst_no = num((ctx.extra or {}).inst_no)
    if inst_no <= 0 then
        return false, "inst_no无效"
    end

    local ok, err = M.can_enter_barrier(player, inst_no)
    if not ok then
        return false, err
    end

    local after = recovery_mgr.change_count(player, STAMINA_ID, -STAMINA_COST)
    if after == nil then
        return false, "扣除体力失败"
    end

    return true, {
        inst_no = inst_no,
        join_data = M.build_rogue_join_data(player, inst_no),
        start_extra = {
            stamina = after,
        },
    }
end

function M.on_play_start_failed(player, ctx, _err)
    local inst_no = num((ctx.extra or {}).inst_no)
    if inst_no > 0 then
        recovery_mgr.change_count(player, STAMINA_ID, STAMINA_COST)
    end
end

function M.before_instance_end(player, ctx)
    local session = ctx.session or {}
    local inst_no = num(session.inst_no)
    local instance_complete_data = type(ctx.complete_data) == "table" and ctx.complete_data or {}
    local stars = M.normalize_stars(instance_complete_data.stars, ctx.success)
    local progress = M.normalize_progress(instance_complete_data.progress)

    local settle_ok, settle_data_or_err = M.calc_settle(player, inst_no, ctx.success, stars, progress)
    if not settle_ok then
        return false, settle_data_or_err
    end

    return true, {
        rewards = settle_data_or_err.rewards,
        reward_reason = "instance_settle",
        settle_data = settle_data_or_err.settle_extra,
    }
end

function M.after_instance_end(player, ctx, _end_data)
    local session = ctx.session or {}
    local inst_no = num(session.inst_no)
    if ctx.success and inst_no > 0 then
        condition_mgr.on_barrier_passed(player, inst_no)
    end
    M.sync_to_client(player)
end

return M
