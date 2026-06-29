--[[
    主线关卡：进度记录、体力校验、结算计算、星级宝箱。
]]

local protocol_handler = require "protocol_handler"
local BARRIER_DATA = require "setting.BARRIER_DATA"
local INSTANCE_DATA = require "setting.INSTANCE_DATA"
local RECOVERY_ENUM = require "setting.RECOVERY_ENUM"
local recovery_mgr = require "system.recovery_mgr"
local item_mgr = require "system.item_mgr"
local condition_mgr = require "system.condition_mgr"
local M = {}

local MAX_STARS = 3

local RECORDS_KEY = "barrier_records"

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

function M.get_cfg(barrier_no)
    return BARRIER_DATA[num(barrier_no)]
end

function M.get_inst_cfg(inst_no)
    return INSTANCE_DATA[num(inst_no)]
end

function M.get_inst_no(barrier_no)
    local cfg = M.get_cfg(barrier_no)
    return cfg and num(cfg.InstNo) or 0
end

local function get_stamina_cost(barrier_cfg)
    return barrier_cfg and num(barrier_cfg.CostStamina) or 0
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

local function get_record(ctn, barrier_no)
    local records = load_records(ctn)
    local record = records[num(barrier_no)]
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

local function write_record(ctn, barrier_no, record, records)
    records[num(barrier_no)] = record
    save_records(ctn, records)
end

function M.get_record(player, barrier_no)
    local ctn = get_ctn(player)
    if not ctn then
        return nil
    end
    return get_record(ctn, barrier_no)
end

function M.is_barrier_passed(player, barrier_no)
    local record = M.get_record(player, barrier_no)
    return record and record.passed or false
end

function M.can_enter_barrier(player, barrier_no)
    barrier_no = num(barrier_no)
    local cfg = M.get_cfg(barrier_no)
    if not cfg then
        return false, "关卡配置不存在"
    end
    if M.get_cfg(barrier_no - 1) and not M.is_barrier_passed(player, barrier_no - 1) then
        return false, "请先通关上一关"
    end
    local stamina = recovery_mgr.get_count(player, RECOVERY_ENUM.STAMINA)
    if stamina == nil then
        return false, "体力数据未就绪"
    end
    local stamina_cost = get_stamina_cost(cfg)
    if stamina_cost <= 0 then
        return false, "关卡体力消耗未配置"
    end
    if stamina < stamina_cost then
        return false, "体力不足"
    end
    local session = player:get_instance_session()
    if type(session) == "table" and session.inst_id then
        return false, "已有进行中的副本"
    end
    return true
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

function M.calc_settle(player, barrier_no, inst_no, success, stars, progress)
    local ctn = get_ctn(player)
    if not ctn then
        return false, "common container not found"
    end

    barrier_no = num(barrier_no)
    inst_no = num(inst_no)
    local barrier_cfg = M.get_cfg(barrier_no)
    if not barrier_cfg then
        return false, "关卡配置不存在"
    end
    local inst_cfg = M.get_inst_cfg(inst_no)
    if not inst_cfg then
        return false, "副本配置不存在"
    end

    stars = M.normalize_stars(stars, success)
    progress = M.normalize_progress(progress)

    local record, records = get_record(ctn, barrier_no)
    local first_pass = not record.passed
    local reward_items = {}

    if success then
        record.passed = true
        if stars > num(record.best_stars) then
            record.best_stars = stars
        end
        if inst_cfg.PassReward then
            merge_items(reward_items, inst_cfg.PassReward)
        end
    end

    write_record(ctn, barrier_no, record, records)

    return true, {
        rewards = reward_items,
        settle_data = {
            barrier_no = barrier_no,
            inst_no = inst_no,
            success = success,
            stars = stars,
            progress = progress,
            best_stars = record.best_stars,
            first_pass = first_pass,
        },
    }
end

function M.can_claim_chest(player, barrier_no, chest_index)
    chest_index = num(chest_index)
    if chest_index < 1 or chest_index > MAX_STARS then
        return false, "宝箱档位无效"
    end
    local cfg = M.get_cfg(barrier_no)
    if not cfg then
        return false, "关卡配置不存在"
    end
    local record = M.get_record(player, barrier_no)
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

function M.claim_chest(player, barrier_no, chest_index)
    barrier_no = num(barrier_no)
    chest_index = num(chest_index)
    local ok, result = M.can_claim_chest(player, barrier_no, chest_index)
    if not ok then
        return false, result
    end

    local ctn = get_ctn(player)
    local record, records = get_record(ctn, barrier_no)
    record.claimed_chests[chest_index] = true
    write_record(ctn, barrier_no, record, records)

    local add_ok, add_err = item_mgr.add_items(player, result, "barrier_chest")
    if not add_ok then
        record.claimed_chests[chest_index] = nil
        write_record(ctn, barrier_no, record, records)
        return false, add_err or "发放奖励失败"
    end

    return true, {
        barrier_no = barrier_no,
        chest_index = chest_index,
        rewards = result,
    }
end

function M.build_sync_list(player)
    local list = {}
    for barrier_no, cfg in pairs(BARRIER_DATA) do
        barrier_no = num(barrier_no)
        local record = M.get_record(player, barrier_no) or {}
        local claimed = {}
        for idx, _ in pairs(record.claimed_chests or {}) do
            claimed[#claimed + 1] = num(idx)
        end
        table.sort(claimed)
        local prev_cfg = M.get_cfg(barrier_no - 1)
        local unlocked = not prev_cfg or M.is_barrier_passed(player, barrier_no - 1)
        local inst_cfg = M.get_inst_cfg(cfg.InstNo)
        list[#list + 1] = {
            barrier_no = barrier_no,
            name = (inst_cfg and inst_cfg.Name) or "",
            unlocked = unlocked,
            passed = record.passed and true or false,
            best_stars = num(record.best_stars),
            claimed_chests = claimed,
        }
    end
    table.sort(list, function(a, b)
        return a.barrier_no < b.barrier_no
    end)
    return list
end

function M.sync_to_client(player)
    if not player or not player.player_id_ then
        return false
    end
    protocol_handler.send_to_player(player.player_id_, "barrier_info_notify", {
        barriers = M.build_sync_list(player),
    })
    return true
end

function M.init_player(player)
    local ctn = get_ctn(player)
    if not ctn then
        return false
    end
    if ctn:get(RECORDS_KEY) == nil then
        ctn:set(RECORDS_KEY, {})
    end
    player:clear_instance_session()
    return true
end

function M.on_player_loaded(player)
    player:clear_instance_session()
    return true
end

function M.clear_session(player)
    if player then
        player:clear_instance_session()
    end
end
 
function M.before_instance_start(player, ctx)
    local extra = ctx.extra or {}
    local barrier_no = num(extra.barrier_no)
    if not M.get_cfg(barrier_no) then
        return false, "关卡配置不存在"
    end

    local ok, err = M.can_enter_barrier(player, barrier_no)
    if not ok then
        return false, err
    end

    local barrier_cfg = M.get_cfg(barrier_no)
    local stamina_cost = get_stamina_cost(barrier_cfg)
    local after = recovery_mgr.change_count(player, RECOVERY_ENUM.STAMINA, -stamina_cost)
    if after == nil then
        return false, "扣除体力失败"
    end
    extra.stamina_cost = stamina_cost

    return true
end

function M.on_play_start_failed(player, ctx, _err)
    local extra = ctx.extra or {}
    local stamina_cost = num(extra.stamina_cost)
    if stamina_cost <= 0 then
        local barrier_no = num(extra.barrier_no)
        local barrier_cfg = barrier_no > 0 and M.get_cfg(barrier_no) or nil
        stamina_cost = get_stamina_cost(barrier_cfg)
    end
    if stamina_cost > 0 then
        recovery_mgr.change_count(player, RECOVERY_ENUM.STAMINA, stamina_cost)
    end
end

function M.before_instance_settle(player, ctx)
    local extra = ctx.extra or {}
    local barrier_no = num(extra.barrier_no)
    local inst_no = num(ctx.inst_no)
    local instance_complete_data = ctx.complete_data or {}
    local stars = M.normalize_stars(instance_complete_data.stars, ctx.success)
    local progress = M.normalize_progress(instance_complete_data.progress)

    local settle_ok, settle_data_or_err = M.calc_settle(player, barrier_no, inst_no, ctx.success, stars, progress)
    if not settle_ok then
        return false, settle_data_or_err
    end

    return true, {
        rewards = settle_data_or_err.rewards,
        reward_reason = "instance_settle",
        settle_data = settle_data_or_err.settle_data,
    }
end

function M.on_instance_settled(player, ctx, _end_data)
    local barrier_no = num((ctx.extra or {}).barrier_no)
    if ctx.success and barrier_no > 0 then
        condition_mgr.on_barrier_passed(player, barrier_no)
    end
    M.sync_to_client(player)
end

function M.on_instance_action(_player, ctx)
    local action = tostring(ctx.action or "")
    if action == "rogue_pick_refresh" then
        -- 由 instance_service.call_play_agent 主动触发时再处理
    end
    return true
end

return M
