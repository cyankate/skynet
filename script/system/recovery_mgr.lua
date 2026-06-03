--[[
    恢复类数值：全部在 common.recovery（含 __meta）。
    Type1/2：check_and_reset 按 get_reset_day_key / get_reset_week_key 做继承重置；
    Type3：get/change/set 时按 RecoverDuration 即时结算。
]]

local log = require "log"
local RECOVERY_DATA = require "setting.RECOVERY_DATA"
local timeutils = require "utils.timeutils"

local M = {
    TYPE = { DAILY = 1, WEEKLY = 2, AUTO = 3 },
}

local STORE_FIELD = "recovery"
local META_KEY = "__meta"

local function get_cfg(recovery_id)
    local cfg = RECOVERY_DATA[recovery_id]
    if not cfg then
        return nil, "recovery config not found"
    end
    return cfg
end

local function clamp_count(count, cfg)
    if cfg.MaxLimit and count > cfg.MaxLimit then
        count = cfg.MaxLimit
    end
    if count < 0 then
        count = 0
    end
    return count
end

local function init_count(cfg)
    return clamp_count(cfg.InitCount or 0, cfg)
end

local function load_store(player)
    local ctn = player:get_ctn("common")
    if not ctn then
        return nil, "common container not ready"
    end
    local store = ctn:get(STORE_FIELD)
    if type(store) ~= "table" then
        store = {}
        ctn:set(STORE_FIELD, store)
    end
    store[META_KEY] = store[META_KEY] or {}
    return store
end

local function save_store(player, store)
    return player:set_common_data(STORE_FIELD, store)
end

--- 结算单条：无 entry 则创建，Type3 跳恢复，返回 entry、是否有改动
local function sync_entry(store, recovery_id, cfg, now)
    now = now or os.time()
    local entry = store[recovery_id]
    local dirty = false
    if not entry then
        entry = { count = init_count(cfg) }
        if cfg.Type == M.TYPE.AUTO then
            entry.last_recover_ts = now
        end
        store[recovery_id] = entry
        dirty = true
    end

    if cfg.Type == M.TYPE.AUTO then
        local recover_limit = cfg.RecoverLimit or cfg.MaxLimit
        local interval_sec = (cfg.RecoverDuration or 0) * 60
        if recover_limit and interval_sec > 0 and entry.count < recover_limit then
            entry.last_recover_ts = entry.last_recover_ts or now
            local ticks = math.floor((now - entry.last_recover_ts) / interval_sec)
            if ticks > 0 then
                entry.count = math.min(
                    entry.count + ticks * (cfg.RecoverCount or 1),
                    recover_limit
                )
                entry.last_recover_ts = entry.last_recover_ts + ticks * interval_sec
                dirty = true
            end
        end
    end

    local c = clamp_count(entry.count, cfg)
    if c ~= entry.count then
        entry.count = c
        dirty = true
    end
    return entry, dirty
end

--- 日/周继承：> InitCount 保留，< InitCount 提到 InitCount
local function do_reset_entry(entry, cfg)
    local target = init_count(cfg)
    if entry.count == nil then
        entry.count = target
        return true
    end
    local cur = clamp_count(entry.count, cfg)
    if cur < target then
        entry.count = target
        return true
    end
    if cur ~= entry.count then
        entry.count = cur
        return true
    end
    return false
end

function M.check_and_reset(player)
    local store, err = load_store(player)
    if not store then
        log.error("recovery check_and_reset: %s", tostring(err))
        return false, err
    end

    local meta = store[META_KEY]
    local now = os.time()
    local day_key = timeutils.get_reset_day_key(now)
    local week_key = timeutils.get_reset_week_key(now)
    local dirty = false

    if meta.last_day_key ~= day_key then
        for recovery_id, cfg in pairs(RECOVERY_DATA) do
            if cfg.Type == M.TYPE.DAILY then
                local entry, _ = sync_entry(store, recovery_id, cfg, now)
                if do_reset_entry(entry, cfg) then
                    dirty = true
                end
            end
        end
        meta.last_day_key = day_key
        dirty = true
    end

    if meta.last_week_key ~= week_key then
        for recovery_id, cfg in pairs(RECOVERY_DATA) do
            if cfg.Type == M.TYPE.WEEKLY then
                local entry, _ = sync_entry(store, recovery_id, cfg, now)
                if do_reset_entry(entry, cfg) then
                    dirty = true
                end
            end
        end
        meta.last_week_key = week_key
        dirty = true
    end

    if dirty then
        save_store(player, store)
    end
    return true
end

function M.init_player(player)
    local store, err = load_store(player)
    if not store then
        log.error("recovery init_player: %s", tostring(err))
        return
    end

    local now = os.time()
    local dirty = false
    for recovery_id, cfg in pairs(RECOVERY_DATA) do
        local entry, changed = sync_entry(store, recovery_id, cfg, now)
        if changed then
            dirty = true
        end
    end
    if dirty then
        save_store(player, store)
    end
    M.check_and_reset(player)
end

function M.get_count(player, recovery_id)
    local cfg, err = get_cfg(recovery_id)
    if not cfg then
        return nil, err
    end
    local store, err2 = load_store(player)
    if not store then
        return nil, err2
    end
    local entry, dirty = sync_entry(store, recovery_id, cfg)
    if dirty then
        save_store(player, store)
    end
    return entry.count
end

function M.change_count(player, recovery_id, delta)
    if type(delta) ~= "number" or delta == 0 then
        return nil, "invalid delta"
    end
    local cfg, err = get_cfg(recovery_id)
    if not cfg then
        return nil, err
    end
    local store, err2 = load_store(player)
    if not store then
        return nil, err2
    end

    local now = os.time()
    local entry, dirty = sync_entry(store, recovery_id, cfg, now)
    local recover_limit = cfg.RecoverLimit or cfg.MaxLimit
    local before = entry.count
    local after = clamp_count(before + delta, cfg)

    if cfg.Type == M.TYPE.AUTO and delta < 0 and recover_limit
        and before >= recover_limit and after < recover_limit then
        entry.last_recover_ts = now
    end
    entry.count = after
    save_store(player, store)
    return after
end

function M.set_count(player, recovery_id, count)
    if type(count) ~= "number" then
        return nil, "invalid count"
    end
    local cfg, err = get_cfg(recovery_id)
    if not cfg then
        return nil, err
    end
    local store, err2 = load_store(player)
    if not store then
        return nil, err2
    end

    local now = os.time()
    local entry, _ = sync_entry(store, recovery_id, cfg, now)
    local recover_limit = cfg.RecoverLimit or cfg.MaxLimit
    local before = entry.count
    entry.count = clamp_count(count, cfg)

    if cfg.Type == M.TYPE.AUTO and recover_limit
        and before >= recover_limit and entry.count < recover_limit then
        entry.last_recover_ts = now
    end
    save_store(player, store)
    return entry.count
end

function M.get_all_counts(player)
    local result = {}
    for recovery_id, cfg in pairs(RECOVERY_DATA) do
        local count = M.get_count(player, recovery_id)
        if count ~= nil then
            result[recovery_id] = count
            if cfg.Enum then
                result[cfg.Enum] = count
            end
        end
    end
    return result
end

return M
