
local skynet = require "skynet"
local class = require "utils.class"
local log = require "log"
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

function Player:save_to_db()
    for _, ctn in pairs(self.ctns_) do
        ctn:save()
    end
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