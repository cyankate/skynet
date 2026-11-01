
local skynet = require "skynet"
local class = require "utils.class"
local log = require "log"
local rpc = require "cluster.rpc"
local db_call = require "system.db_call"
local item_mgr = require "system.item_mgr"
local recovery_mgr = require "system.recovery_mgr"
local head_mgr = require "system.head_mgr"
local barrier_mgr = require "system.barrier_mgr"
local condition_mgr = require "system.condition_mgr"
local task_mgr = require "system.task.task_mgr"
local effect_mgr = require "system.effect_mgr"
local weapon_mgr = require "system.weapon_mgr"
local Player = class("Player")

function Player:ctor(_player_id, _player_data)
    self.player_id_ = _player_id
    self.player_name_ = _player_data.player_name
    self.account_key_ = _player_data.account_key
    self.ctns_ = {} -- 存储容器对象
    self.ctn_loading_ = {} -- 正在加载的容器
    self.loaded_ = false
    self.is_new_ = _player_data.is_new == true
    self.flow_state_ = "idle"
    self.flow_version_ = 0
    self.instance_session_ = nil
end

--- 新号初始化：容器 load 完成后写入默认数据
function Player:init_new_player()
    head_mgr.init_player(self)
    weapon_mgr.try_unlock_by_level(self, head_mgr.get_head_level(self))
    barrier_mgr.init_player(self)
    local condition = self:get_ctn("condition")
    if condition then
        condition:init_player()
    end
    local task = self:get_ctn("task")
    if task then
        task:init_player()
    end
end

function Player:on_loaded()
    -- 这里可以添加玩家加载完成后的逻辑
    log.info(string.format("Player %s on_loaded successfully", self.player_id_))
    -- 例如通知其他服务，或者进行一些初始化操作
    self.loaded_ = true

    recovery_mgr.init_player(self)
    weapon_mgr.try_unlock_by_level(self, head_mgr.get_head_level(self))
    barrier_mgr.on_player_loaded(self)
    condition_mgr.sync_from_player(self)
    task_mgr.on_player_loaded(self)

    local rankS = skynet.localname(".rank")
    skynet.send(rankS, "lua", "update_rank", "score", {
        player_id = self.player_id_,
        score = 100,
    })
end 

function Player:get_ctn(name)
    return self.ctns_[name]
end

-- 玩家级串行队列：定时 save 和关键提交共用，避免旧快照覆盖新数据
function Player:save_queue()
    self.save_queue_ = self.save_queue_ or require("skynet.queue")()
    return self.save_queue_
end

function Player:exclusive(fn, ...)
    return self:save_queue()(fn, ...)
end

local function save_ctns(player)
    local ok = true
    for name, ctn in pairs(player.ctns_) do
        -- 关键提交还没成功时，先不把这个容器写出去，避免“内存已生效、op_log 未提交”
        if not (player.pending_critical_ and player.pending_critical_[name]) then
            local saved = ctn:save_now()
            if not saved then
                ok = false
            end
        end
    end
    return ok
end

function Player:save_to_db()
    skynet.fork(function()
        self:exclusive(function()
            save_ctns(self)
        end)
    end)
end

-- 同步保存：卸载、关服等需要确认落库的场景
function Player:save_to_db_sync()
    return self:exclusive(function()
        return save_ctns(self)
    end)
end

-- 关键提交：把指定容器的当前快照 + op_log 放进同一个 DB 事务。
-- 调用方应先改内存；返回 false 时内存改动仍在，调用方需按同一 op_id 重试。
function Player:commit_critical(op_id, container_names, extra_ops, result)
    local db = skynet.localname(".db")
    if not db then
        return false, "db unavailable"
    end
    return self:exclusive(function()
        local ops = {}
        for _, op in ipairs(extra_ops or {}) do
            ops[#ops + 1] = op
        end
        local snapshots = {}
        for _, name in ipairs(container_names or {}) do
            local ctn = self.ctns_[name]
            local tbl = ctn and ctn.tbl_
            if ctn and tbl then
                local rows = ctn:snapshot_rows()
                snapshots[#snapshots + 1] = { ctn = ctn, rows = rows }
                for _, row in ipairs(rows) do
                    ops[#ops + 1] = { op = "upsert", tbl = tbl, data = row }
                end
            end
        end
        if #ops == 0 then
            return false, "no ops"
        end
        local completed, ok, res, err = rpc.call_timeout(db, 1000, "commit_op", op_id, ops, result)
        if not completed then
            -- 超时：事务可能已经提交，按 op_id 回查，避免误判后回滚内存
            local recovered, recovered_result = false, nil
            for _ = 1, 2 do
                local rec_ok, exists, old = rpc.call_timeout(db, 500, "op_get", op_id)
                if rec_ok and exists then
                    recovered, recovered_result = true, old
                    break
                end
                skynet.sleep(100)
            end
            if recovered then
                ok, res = true, recovered_result
            else
                return false, "commit timeout"
            end
        end
        if not ok then
            return false, err or res
        end
        for _, item in ipairs(snapshots) do
            item.ctn:mark_rows_saved(item.rows)
            item.ctn:clear_dirty()
            item.ctn.last_save_time_ = skynet.time()
        end
        return true, res
    end)
end

-- 单玩家关键扣物品：先扣内存，事务失败则恢复内存；op_id 幂等
function Player:cost_items_critical(op_id, items, extra_ops, result, reason)
    if type(op_id) ~= "string" or op_id == "" then
        return false, "invalid op_id"
    end
    return self:exclusive(function()
        local db = skynet.localname(".db")
        if db then
            local exists, old = db_call.call("op_get", op_id)
            if exists then
                return true, old
            end
        end
        local ok, err = item_mgr.cost_items(self, items, reason or "critical_cost")
        if not ok then
            return false, err
        end
        local commit_ok, res, cerr = self:commit_critical(op_id, { "bag" }, extra_ops, result)
        if commit_ok then
            return true, res
        end
        -- 事务失败：把扣掉的物品加回内存，避免玩家白丢（不跑礼包转换规则）
        local restore_ok, rerr = item_mgr.restore_items(self, items, (reason or "critical_cost") .. "_rollback")
        if not restore_ok then
            log.error("critical cost rollback failed, op=%s err=%s", tostring(op_id), tostring(rerr))
        end
        return false, cerr or res
    end)
end

-- 单玩家关键发奖：op_id 幂等；提交失败时保留 pending，定时保存先跳过背包
function Player:grant_items_critical(op_id, items, reason, extra_ops)
    if type(op_id) ~= "string" or op_id == "" then
        return false, "invalid op_id"
    end
    self.pending_ops_ = self.pending_ops_ or {}
    self.pending_critical_ = self.pending_critical_ or {}
    return self:exclusive(function()
        local db = skynet.localname(".db")
        if db then
            local exists, old = db_call.call("op_get", op_id)
            if exists then
                return true, old
            end
        end
        if not self.pending_ops_[op_id] then
            local ok, err = item_mgr.add_items(self, items, reason or "critical_grant")
            if not ok then
                return false, err
            end
            self.pending_ops_[op_id] = true
            self.pending_critical_["bag"] = true
        end
        local ok, res, err = self:commit_critical(op_id, { "bag" }, extra_ops, { items = items })
        if ok then
            self.pending_ops_[op_id] = nil
            self.pending_critical_["bag"] = nil
            return true, res
        end
        return false, err or res
    end)
end

function Player:add_item(_item_id, _count)
    return item_mgr.add_items(self, {
        [_item_id] = _count,
    }, "player_add_item")
end

function Player:get_flow_state()
    return self.flow_state_ or "idle", self.flow_version_ or 0
end

function Player:set_flow_state(new_state)
    local old_state = self.flow_state_ or "idle"
    self.flow_state_ = new_state or "idle"
    self.flow_version_ = (self.flow_version_ or 0) + 1
    return old_state, self.flow_state_, self.flow_version_
end

function Player:get_instance_session()
    return self.instance_session_
end

function Player:set_instance_session(session)
    self.instance_session_ = session
end

function Player:clear_instance_session()
    self.instance_session_ = nil
end

function Player:try_set_flow_state(expected_states, new_state)
    local current = self.flow_state_ or "idle"
    local allowed = false
    for _, state in ipairs(expected_states or {}) do
        if state == current then
            allowed = true
            break
        end
    end
    if not allowed then
        return false, current
    end
    self:set_flow_state(new_state)
    return true, self.flow_state_
end

--- 日周期桶内字段；cycle_offset=0 当前日，-1 上一日
function Player:get_day_data(field_key, cycle_offset)
    local ctn = self:get_ctn("day")
    if not ctn then
        return false, "Day not found"
    end
    return ctn:get_field(field_key, cycle_offset or 0)
end

function Player:set_day_data(field_key, value, cycle_offset)
    local ctn = self:get_ctn("day")
    if not ctn then
        return false, "Day not found"
    end
    return ctn:set_field(field_key, value, cycle_offset or 0)
end

--- 周周期桶内字段；cycle_offset=0 当前周，-1 上一周
function Player:get_week_data(field_key, cycle_offset)
    local ctn = self:get_ctn("week")
    if not ctn then
        return false, "Week not found"
    end
    return ctn:get_field(field_key, cycle_offset or 0)
end

function Player:set_week_data(field_key, value, cycle_offset)
    local ctn = self:get_ctn("week")
    if not ctn then
        return false, "Week not found"
    end
    return ctn:set_field(field_key, value, cycle_offset or 0)
end

function Player:get_common_data(field_key, default)
    local ctn = self:get_ctn("common")
    local v = ctn:get(field_key)
    if v == nil then
        return default
    end
    return v
end

function Player:set_common_data(field_key, value)
    local ctn = self:get_ctn("common")
    return ctn:set(field_key, value)
end

function Player:get_level()
    return head_mgr.get_head_level(self)
end

function Player:get_exp()
    return head_mgr.get_head_exp(self)
end

--- 进本前打包：基础信息、武器等级、养成效果 id
function Player:build_instance_pack()
    local effects = effect_mgr.get_effects(self)
    if not effects then
        return nil
    end

    local weapon_levels = {}
    for _, weapon_id in ipairs(weapon_mgr.get_unlocked_weapon_ids(self)) do
        weapon_levels[weapon_id] = weapon_mgr.get_weapon_level(self, weapon_id)
    end

    return {
        player_id = self.player_id_,
        player_name = self.player_name_,
        head_id = head_mgr.get_head_id(self),
        head_level = head_mgr.get_head_level(self),
        weapon_levels = weapon_levels,
        effect_ids = effects:get_effect_ids(),
    }
end

return Player