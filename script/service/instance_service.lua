local skynet = require "skynet"
local log = require "log"
local instance_mgr = require "instance.instance_mgr"
local inst_def = require "define.inst_def"
local InstanceStatus = inst_def.InstanceStatus
local InstanceEndType = inst_def.InstanceEndType
local InstanceEndReason = inst_def.InstanceEndReason
local tableUtils = require "utils.tableUtils"
local protocol_handler = require "protocol_handler"
local service_ctx = require "runtime.service_ctx"

local UPDATE_INTERVAL_TICK = 10
local GLOBAL_INSTANCE_TIMEOUT_SEC = 3600
local COMPLETED_INSTANCE_GC_SEC = 120

local M = service_ctx.get("instance.instance", {})
M.running = (M.running ~= false)
M.scene_counter = M.scene_counter or 0
M.instance_scene_map = M.instance_scene_map or {}
M._inited = M._inited or false

local function get_instance_or_error(inst_id)
    local inst = instance_mgr.get_instance(inst_id)
    if not inst then
        return nil, false, "副本不存在"
    end
    return inst, true
end

local function try_destroy_if_empty(inst_id, inst)
    if tableUtils.table_size(inst.pjoins_) > 0 then
        return false
    end
    M.destroy_instance(inst_id)
    return true
end

local function get_agent_flow(player_id)
    local ok, result_or_err = protocol_handler.call_agent(player_id, "get_player_flow", { player_id = player_id })
    if not ok then
        return nil, result_or_err or "query flow failed"
    end
    return (result_or_err and result_or_err.flow_state) or "idle"
end

local function update_loop()
    while M.running do
        instance_mgr.update(0.1)
        local now = os.time()
        local destroy_list = {}
        for inst_id, data in pairs(instance_mgr.instances or {}) do
            local inst = data and data.inst
            if inst then
                local status = inst:get_status()
                local global_timeout = tonumber((inst.args_ or {}).global_timeout_seconds) or GLOBAL_INSTANCE_TIMEOUT_SEC
                local create_time = tonumber(inst.create_time_ or now) or now
                if (status == InstanceStatus.WAITING or status == InstanceStatus.RUNNING or status == InstanceStatus.PAUSED) and now - create_time >= global_timeout then
                    inst:complete(false, {
                        end_type = InstanceEndType.TIMEOUT,
                        end_reason = InstanceEndReason.TIMEOUT_SERVER,
                        timeout_source = "instance_global",
                    })
                    table.insert(destroy_list, inst_id)
                elseif status == InstanceStatus.COMPLETED then
                    local end_time = tonumber(inst.end_time_ or now) or now
                    if now - end_time >= COMPLETED_INSTANCE_GC_SEC then
                        table.insert(destroy_list, inst_id)
                    end
                end
            end
        end
        for _, inst_id in ipairs(destroy_list) do
            M.destroy_instance(inst_id)
        end
        skynet.sleep(UPDATE_INTERVAL_TICK)
    end
end

function M.init()
    if M._inited then
        return true
    end
    M._inited = true
    instance_mgr.init()
    skynet.fork(update_loop)
    return true
end

function M.create_instance(type_name, args)
    args = args or {}
    local inst_id = instance_mgr.create_instance(type_name, args)
    if not inst_id then
        return false, "创建副本失败"
    end
    return true, inst_id
end

function M.destroy_instance(inst_id)
    local scene_data = M.instance_scene_map[inst_id]
    if scene_data then
        local scene = skynet.localname(".scene")
        if scene then
            skynet.call(scene, "lua", "destroy_scene", scene_data.scene_id)
        end
        M.instance_scene_map[inst_id] = nil
    end
    local ok = instance_mgr.destroy_instance(inst_id)
    return ok and true or false, ok and nil or "副本销毁失败"
end

function M.create_and_enter_batch(type_name, args, players, join_data_map)
    args = args or {}
    players = players or {}
    join_data_map = join_data_map or {}
    if #players == 0 then
        return false, "匹配玩家为空", { stage = "precheck" }
    end
    for _, player_id in ipairs(players) do
        local in_inst, current_inst_id = instance_mgr.get_player_instance(player_id)
        if in_inst then
            return false, "玩家已在副本中", { stage = "precheck", player_id = player_id, current_inst_id = current_inst_id }
        end
    end
    local create_ok, inst_id_or_err = M.create_instance(type_name, args)
    if not create_ok then
        return false, inst_id_or_err or "创建副本失败", { stage = "create" }
    end
    local inst_id = inst_id_or_err
    for _, player_id in ipairs(players) do
        local join_ok, join_err = instance_mgr.join_instance(inst_id, player_id, join_data_map[player_id] or {})
        if not join_ok then
            M.destroy_instance(inst_id)
            return false, join_err or "加入副本失败", { stage = "join", inst_id = inst_id, player_id = player_id }
        end
    end
    for _, player_id in ipairs(players) do
        local enter_ok, enter_err = M.enter_instance(inst_id, player_id)
        if not enter_ok then
            M.destroy_instance(inst_id)
            return false, enter_err or "进入副本失败", { stage = "enter", inst_id = inst_id, player_id = player_id }
        end
    end
    return true, {
        inst_id = inst_id,
        scene_id = M.instance_scene_map[inst_id] and M.instance_scene_map[inst_id].scene_id or 0,
        players = players,
    }
end

function M.play_start_direct(player_id, type_name, options)
    local opt = options or {}
    local in_inst, current_inst_id = instance_mgr.get_player_instance(player_id)
    if in_inst then
        return false, "玩家已在副本中"
    end
    local flow = get_agent_flow(player_id) or "idle"
    if flow == "matching" or flow == "pending_confirm" then
        return false, "玩家匹配中，无法直接进入副本"
    end
    local create_ok, inst_id_or_err = M.create_instance(
        opt.instance_type_name or type_name or "single",
        {
            inst_no = opt.inst_no,
            ready_mode = opt.ready_mode or "auto",
            creator_id = player_id,
            type_name = type_name,
            join_data = opt.join_data or {},
            mode_type = opt.mode_type,
            mode_config = opt.mode_config,
        }
    )
    if not create_ok then
        return false, inst_id_or_err
    end
    local inst_id = inst_id_or_err
    local join_ok, join_err = instance_mgr.join_instance(inst_id, player_id, opt.join_data or {})
    if not join_ok then
        M.destroy_instance(inst_id)
        return false, join_err or "加入副本失败"
    end
    local enter_ok, enter_err = M.enter_instance(inst_id, player_id)
    if not enter_ok then
        M.destroy_instance(inst_id)
        return false, enter_err or "进入副本失败"
    end
    return true, { inst_id = inst_id, scene_id = M.instance_scene_map[inst_id] and M.instance_scene_map[inst_id].scene_id or 0 }
end

function M.enter_instance(inst_id, player_id)
    local inst, ok, err = get_instance_or_error(inst_id)
    if not ok then
        return ok, err
    end
    if not inst:has_player(player_id) then
        return false, "玩家未加入副本"
    end
    local scene_data = M.instance_scene_map[inst_id]
    local scene_entered = false
    if scene_data then
        local scene = skynet.localname(".scene")
        if scene then
            local enter_ok, enter_err = skynet.call(scene, "lua", "enter_scene", scene_data.scene_id, {
                id = player_id, type = "player", x = scene_data.spawn_x, y = scene_data.spawn_y, properties = { instance_id = inst_id },
            })
            if not enter_ok then
                return false, enter_err or "进入副本场景失败"
            end
            scene_entered = true
        end
    end
    local enter_ok, enter_err = inst:enter(player_id)
    if not enter_ok then
        if scene_entered then
            local scene = skynet.localname(".scene")
            if scene and scene_data then
                skynet.call(scene, "lua", "leave_scene", scene_data.scene_id, player_id)
            end
        end
        return false, enter_err or "进入副本失败"
    end
    if instance_mgr.is_auto_start(inst_id) and inst:get_status() ~= InstanceStatus.RUNNING then
        inst:start()
    end
    return true
end

function M.exit_instance(inst_id, player_id)
    local inst, ok, err = get_instance_or_error(inst_id)
    if not ok then
        return ok, err
    end
    local scene_data = M.instance_scene_map[inst_id]
    if scene_data then
        local scene = skynet.localname(".scene")
        if scene then
            skynet.call(scene, "lua", "leave_scene", scene_data.scene_id, player_id)
        end
    end
    local exit_ok, exit_err = instance_mgr.exit_instance(inst_id, player_id)
    if not exit_ok then
        return false, exit_err or "退出副本失败"
    end
    return true
end

function M.start_instance(inst_id)
    local inst, ok, err = get_instance_or_error(inst_id)
    if not ok then
        return ok, err
    end
    if not inst:start() then
        return false, "副本状态不允许启动"
    end
    return true
end

function M.ready_instance(inst_id, player_id)
    local ok, msg, should_start = instance_mgr.ready_instance(inst_id, player_id)
    if not ok then
        return false, msg or "准备失败"
    end
    if not should_start then
        return true, msg
    end
    local inst, inst_ok, inst_err = get_instance_or_error(inst_id)
    if not inst_ok then
        return false, inst_err
    end
    if not inst:start() then
        return false, "副本状态不允许准备开始"
    end
    return true, msg
end

function M.instance_mode_event(inst_id, player_id, event_type, payload)
    local inst, ok, err = get_instance_or_error(inst_id)
    if not ok then
        return ok, err
    end
    if not inst:has_player(player_id) then
        return false, "玩家未加入副本"
    end
    local ok_event, err_event = inst:emit_mode_event(event_type, payload or {})
    if not ok_event then
        return false, err_event
    end
    return true
end

function M.quit_instance(inst_id, player_id)
    local inst, ok, err = get_instance_or_error(inst_id)
    if not ok then
        return ok, err
    end
    local scene_data = M.instance_scene_map[inst_id]
    if scene_data and inst.penters_[player_id] then
        local scene = skynet.localname(".scene")
        if scene then
            skynet.call(scene, "lua", "leave_scene", scene_data.scene_id, player_id)
        end
    end
    local quit_ok, quit_err = instance_mgr.quit_instance(inst_id, player_id)
    if not quit_ok then
        return false, quit_err or "退出副本失败"
    end
    if tableUtils.table_size(inst.pjoins_) == 0 then
        local inst_data = instance_mgr.get_instance_data(inst_id)
        if inst_data and inst_data.type == "multi" and inst:get_status() ~= InstanceStatus.COMPLETED then
            inst:complete(false, {
                reason = "all_quit",
                end_type = InstanceEndType.ACTIVE_QUIT,
                end_reason = InstanceEndReason.QUIT_ALL,
            })
        end
        try_destroy_if_empty(inst_id, inst)
    end
    return true
end

function M.pause_instance(inst_id)
    local inst, ok, err = get_instance_or_error(inst_id)
    if not ok then
        return ok, err
    end
    if not inst:pause() then
        return false, "副本状态不允许暂停"
    end
    return true
end

function M.resume_instance(inst_id)
    local inst, ok, err = get_instance_or_error(inst_id)
    if not ok then
        return ok, err
    end
    if not inst:resume() then
        return false, "副本状态不允许恢复"
    end
    return true
end

function M.complete_instance(inst_id, success, data_)
    local inst, ok, err = get_instance_or_error(inst_id)
    if not ok then
        return ok, err
    end
    if not inst:complete(success, data_) then
        return false, "副本状态不允许结束"
    end
    return true
end

function M.get_instance_status(inst_id)
    local inst, ok, err = get_instance_or_error(inst_id)
    if not ok then
        return ok, err
    end
    return true, inst:get_status()
end

function M.get_instance_info(inst_id)
    local inst, ok, err = get_instance_or_error(inst_id)
    if not ok then
        return ok, err
    end
    return true, {
        inst_id = inst.inst_id_,
        inst_no = inst.inst_no_,
        status = inst.status_,
        create_time = inst.create_time_,
        start_time = inst.start_time_,
        end_time = inst.end_time_,
        duration = inst.duration_,
        scene_id = M.instance_scene_map[inst_id] and M.instance_scene_map[inst_id].scene_id or 0,
        join_count = tableUtils.table_size(inst.pjoins_),
        enter_count = tableUtils.table_size(inst.penters_),
    }
end

function M.list_instances()
    local list = {}
    for inst_id, data in pairs(instance_mgr.instances) do
        list[inst_id] = {
            type = data.type,
            create_time = data.create_time,
            status = data.inst and data.inst:get_status() or 0,
            scene_id = M.instance_scene_map[inst_id] and M.instance_scene_map[inst_id].scene_id or 0,
        }
    end
    return true, list
end

function M.get_player_instance(player_id)
    return instance_mgr.get_player_instance(player_id)
end

function M.get_player_flow(player_id)
    local flow = get_agent_flow(player_id)
    if not flow then
        return false, "获取玩家流程态失败"
    end
    return true, flow
end

function M.try_enter_match_flow(player_id)
    local in_inst = instance_mgr.get_player_instance(player_id)
    if in_inst then
        return false, "玩家已在副本中"
    end
    local ok, err_or_state = protocol_handler.call_agent(player_id, "try_set_player_flow", {
        player_id = player_id, expected_states = { "idle" }, new_state = "matching", reason = "match_start",
    })
    if not ok then
        return false, err_or_state or "玩家当前状态不可进入匹配"
    end
    return true
end

function M.mark_pending_confirm(player_ids)
    for _, player_id in ipairs(player_ids or {}) do
        protocol_handler.call_agent(player_id, "try_set_player_flow", {
            player_id = player_id, expected_states = { "matching", "pending_confirm" }, new_state = "pending_confirm", reason = "match_pending_confirm",
        })
    end
    return true
end

function M.clear_match_flow(player_ids)
    for _, player_id in ipairs(player_ids or {}) do
        protocol_handler.call_agent(player_id, "try_set_player_flow", {
            player_id = player_id, expected_states = { "matching", "pending_confirm" }, new_state = "idle", reason = "match_flow_clear",
        })
    end
    return true
end

function M.sync_player_instance_state(player_id)
    local in_inst, inst_id_or_err = instance_mgr.get_player_instance(player_id)
    if not in_inst then
        return true
    end
    local inst_id = inst_id_or_err
    local inst = instance_mgr.get_instance(inst_id)
    if not inst or not inst:has_player(player_id) then
        return true
    end
    if inst.build_play_data_notify then
        protocol_handler.send_to_player(player_id, "instance_play_data_notify", inst:build_play_data_notify())
    end
    return true
end

function M.call_play_agent(inst, player_id, action, payload)
    local args = inst.args_ or {}
    local type_name = args.type_name
    if type_name == nil or type_name == "" then
        return true
    end
    local ok, result = protocol_handler.call_agent(player_id, "instance_play_action", {
        player_id = player_id,
        inst_id = inst.inst_id_,
        inst_no = inst.inst_no_ or 0,
        type_name = type_name,
        action = action,
        payload = payload or {},
    })
    if not ok then
        return false, result or "agent交互失败"
    end
    return true, result
end

local function get_rogue_inst(inst_id, player_id)
    local inst, ok, err = get_instance_or_error(inst_id)
    if not ok then
        return nil, ok, err
    end
    if not inst.rogue_open_pick then
        return nil, false, "当前副本不支持肉鸽"
    end
    if player_id and not inst:has_player(player_id) then
        return nil, false, "玩家未在副本中"
    end
    return inst, true
end

function M.rogue_pick_open(inst_id, player_id)
    local inst, ok, err = get_rogue_inst(inst_id, player_id)
    if not ok then
        return ok, err
    end
    local open_ok, result = inst:rogue_open_pick()
    if not open_ok then
        return false, result
    end
    protocol_handler.send_to_player(player_id, "rogue_pick_notify", {
        inst_id = inst_id,
        pick_index = result.pick_index,
        options = result.options,
    })
    return true, result
end

function M.rogue_pick_refresh(inst_id, player_id)
    local inst, ok, err = get_rogue_inst(inst_id, player_id)
    if not ok then
        return ok, err
    end
    local refresh_ok, result = inst:rogue_refresh_pick()
    if not refresh_ok then
        return false, result
    end
    protocol_handler.send_to_player(player_id, "rogue_pick_notify", {
        inst_id = inst_id,
        pick_index = result.pick_index,
        options = result.options,
    })
    return true, result
end

function M.rogue_pick_select(inst_id, player_id, choice_index)
    local inst, ok, err = get_rogue_inst(inst_id, player_id)
    if not ok then
        return ok, err
    end
    local select_ok, result = inst:rogue_select_pick(choice_index)
    if not select_ok then
        return false, result
    end
    protocol_handler.send_to_player(player_id, "rogue_state_notify", {
        inst_id = inst_id,
        sync = inst:build_rogue_sync(),
    })
    return true, result
end

function M.shutdown()
    M.running = false
    local scene = skynet.localname(".scene")
    if scene then
        for _, data in pairs(M.instance_scene_map) do
            skynet.call(scene, "lua", "destroy_scene", data.scene_id)
        end
    end
    M.instance_scene_map = {}
    instance_mgr.shutdown()
    return true
end

return M
