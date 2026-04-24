local skynet = require "skynet"
local log = require "log"
local service_wrapper = require "utils.service_wrapper"
local instance_mgr = require "instance.instance_mgr"
local inst_def = require "define.inst_def"
local InstanceStatus = inst_def.InstanceStatus
local InstanceEndType = inst_def.InstanceEndType
local InstanceEndReason = inst_def.InstanceEndReason
local tableUtils = require "utils.tableUtils"
local user_mgr = require "user_mgr"
local protocol_handler = require "protocol_handler"

local UPDATE_INTERVAL_TICK = 10 -- 0.1s
local GLOBAL_INSTANCE_TIMEOUT_SEC = 3600
local COMPLETED_INSTANCE_GC_SEC = 120
local running = true
local scene_counter = 0
local instance_scene_map = {} -- inst_id -> { scene_id, spawn_x, spawn_y }

local function get_instance_or_error(inst_id)
    local inst = instance_mgr.get_instance(inst_id)
    if not inst then
        return nil, false, "副本不存在"
    end
    return inst, true
end

local function generate_scene_id()
    scene_counter = scene_counter + 1
    return 9000000 + scene_counter
end

local function get_agent_flow(player_id)
    local ok, result_or_err = protocol_handler.call_agent(player_id, "get_player_flow", {
        player_id = player_id,
    })
    if not ok then
        return nil, result_or_err or "query flow failed"
    end
    return (result_or_err and result_or_err.flow_state) or "idle"
end

local function update_loop()
    while running do
        instance_mgr.update(0.1)
        local now = os.time()
        local destroy_list = {}
        for inst_id, data in pairs(instance_mgr.instances or {}) do
            local inst = data and data.inst
            if inst then
                local status = inst:get_status()
                local global_timeout = tonumber((inst.args_ or {}).global_timeout_seconds) or GLOBAL_INSTANCE_TIMEOUT_SEC
                local create_time = tonumber(inst.create_time_ or now) or now
                if (status == InstanceStatus.WAITING or status == InstanceStatus.RUNNING or status == InstanceStatus.PAUSED)
                    and now - create_time >= global_timeout then
                    log.warning("instance.global_timeout inst_id=%s status=%s timeout=%s", tostring(inst_id), tostring(status), tostring(global_timeout))
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
            CMD.destroy_instance(inst_id)
        end
        skynet.sleep(UPDATE_INTERVAL_TICK)
    end
end

function CMD.init()
    instance_mgr.init()
    skynet.fork(update_loop)
    log.info("instance service init")
    return true
end

function CMD.create_instance(type_name, args)
    args = args or {}
    log.info("instance.create request type=%s inst_no=%s mode=%s creator=%s", tostring(type_name), tostring(args.inst_no), tostring(args.mode_type), tostring(args.creator_id))
    local inst_id = instance_mgr.create_instance(type_name, args)
    if not inst_id then
        log.error("instance.create failed type=%s inst_no=%s", tostring(type_name), tostring(args.inst_no))
        return false, "创建副本失败"
    end
    log.info("instance.create ok inst_id=%s type=%s", tostring(inst_id), tostring(type_name))
    return true, inst_id
end

function CMD.destroy_instance(inst_id)
    log.info("instance.destroy request inst_id=%s", tostring(inst_id))
    local scene_data = instance_scene_map[inst_id]
    if scene_data then
        local scene = skynet.localname(".scene")
        if scene then
            skynet.call(scene, "lua", "destroy_scene", scene_data.scene_id)
        end
        instance_scene_map[inst_id] = nil
    end
    local ok = instance_mgr.destroy_instance(inst_id)
    if ok then
        log.info("instance.destroy ok inst_id=%s", tostring(inst_id))
    else
        log.error("instance.destroy failed inst_id=%s", tostring(inst_id))
    end
    return ok and true or false, ok and nil or "副本销毁失败"
end

function CMD.create_and_enter_batch(type_name, args, players, join_data_map)
    log.info("instance.batch_start type=%s players=%d ready_mode=%s mode=%s", tostring(type_name), #players, tostring(args.ready_mode), tostring(args.mode_type))
    -- 多人编排入口：用于匹配/组队场景，不用于单人直进。
    args = args or {}
    players = players or {}
    join_data_map = join_data_map or {}

    if #players == 0 then
        return false, "匹配玩家为空", { stage = "precheck" }
    end

    for _, player_id in ipairs(players) do
        local in_inst, current_inst_id = instance_mgr.get_player_instance(player_id)
        if in_inst then
            return false, "玩家已在副本中", {
                stage = "precheck",
                player_id = player_id,
                current_inst_id = current_inst_id,
            }
        end
    end

    local create_ok, inst_id_or_err = CMD.create_instance(type_name, args)
    if not create_ok then
        return false, inst_id_or_err or "创建副本失败", { stage = "create" }
    end

    local inst_id = inst_id_or_err
    for _, player_id in ipairs(players) do
        local join_ok, join_err = instance_mgr.join_instance(inst_id, player_id, join_data_map[player_id] or {})
        if not join_ok then
            CMD.destroy_instance(inst_id)
            return false, join_err or "加入副本失败", {
                stage = "join",
                inst_id = inst_id,
                player_id = player_id,
            }
        end
    end

    for _, player_id in ipairs(players) do
        local enter_ok, enter_err = CMD.enter_instance(inst_id, player_id)
        if not enter_ok then
            CMD.destroy_instance(inst_id)
            return false, enter_err or "进入副本失败", {
                stage = "enter",
                inst_id = inst_id,
                player_id = player_id,
            }
        end
    end

    return true, {
        inst_id = inst_id,
        scene_id = instance_scene_map[inst_id] and instance_scene_map[inst_id].scene_id or 0,
        players = players,
    }
end

function CMD.play_start_direct(player_id, type_name, options)
    local opt = options or {}
    log.info("instance.direct_start player=%s type_name=%s instance_type=%s mode=%s", tostring(player_id), tostring(type_name), tostring(opt.instance_type_name or type_name), tostring(opt.mode_type))
    local in_inst, current_inst_id = instance_mgr.get_player_instance(player_id)
    if in_inst then
        log.warning("instance.direct_start rejected player=%s current_inst_id=%s", tostring(player_id), tostring(current_inst_id))
        return false, "玩家已在副本中"
    end
    local flow = get_agent_flow(player_id) or "idle"
    if flow == "matching" or flow == "pending_confirm" then
        log.warning("instance.direct_start rejected player=%s flow=%s", tostring(player_id), tostring(flow))
        return false, "玩家匹配中，无法直接进入副本"
    end
    local create_ok, inst_id_or_err = CMD.create_instance(
        opt.instance_type_name or type_name or "single",
        {
            inst_no = opt.inst_no,
            ready_mode = opt.ready_mode or "auto",
            creator_id = player_id,
            type_name = type_name,
            result_source = opt.result_source or "server",
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
        CMD.destroy_instance(inst_id)
        return false, join_err or "加入副本失败"
    end
    local enter_ok, enter_err = CMD.enter_instance(inst_id, player_id)
    if not enter_ok then
        CMD.destroy_instance(inst_id)
        return false, enter_err or "进入副本失败"
    end

    local scene_id = instance_scene_map[inst_id] and instance_scene_map[inst_id].scene_id or 0
    return true, {
        inst_id = inst_id,
        scene_id = scene_id,
    }
end

function CMD.enter_instance(inst_id, player_id)
    log.info("instance.enter request inst_id=%s player=%s", tostring(inst_id), tostring(player_id))
    local inst, ok, err = get_instance_or_error(inst_id)
    if not ok then
        return ok, err
    end

    if not inst:has_player(player_id) then
        return false, "玩家未加入副本"
    end

    local scene_data = instance_scene_map[inst_id]
    local scene_entered = false
    if scene_data then
        local scene = skynet.localname(".scene")
        if scene then
            local enter_ok, enter_err = skynet.call(scene, "lua", "enter_scene", scene_data.scene_id, {
                id = player_id,
                type = "player",
                x = scene_data.spawn_x,
                y = scene_data.spawn_y,
                properties = {
                    instance_id = inst_id,
                },
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
        local started = inst:start()
        if started then
            log.info("instance auto started, inst_id=%s", tostring(inst_id))
        end
    end
    return true
end

function CMD.exit_instance(inst_id, player_id)
    log.info("instance.exit request inst_id=%s player=%s", tostring(inst_id), tostring(player_id))
    local inst, ok, err = get_instance_or_error(inst_id)
    if not ok then
        return ok, err
    end

    local scene_data = instance_scene_map[inst_id]
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

function CMD.start_instance(inst_id)
    local inst, ok, err = get_instance_or_error(inst_id)
    if not ok then
        return ok, err
    end
    local started = inst:start()
    if not started then
        return false, "副本状态不允许启动"
    end
    return true
end

function CMD.ready_instance(inst_id, player_id)
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
    local started = inst:start()
    if not started then
        return false, "副本状态不允许准备开始"
    end
    return true, msg
end

function CMD.instance_mode_event(inst_id, player_id, event_type, payload)
    log.info("instance.mode_event request inst_id=%s player=%s event=%s value=%s target=%s", tostring(inst_id), tostring(player_id), tostring(event_type), tostring(payload and payload.event_value), tostring(payload and payload.target_id))
    local inst, ok, err = get_instance_or_error(inst_id)
    if not ok then
        return ok, err
    end
    if not inst:has_player(player_id) then
        return false, "玩家未加入副本"
    end
    local ok_event, err_event = inst:emit_mode_event(event_type, payload or {})
    if not ok_event then
        log.warning("instance.mode_event rejected inst_id=%s player=%s event=%s err=%s", tostring(inst_id), tostring(player_id), tostring(event_type), tostring(err_event))
        return false, err_event
    end
    log.info("instance.mode_event accepted inst_id=%s player=%s event=%s", tostring(inst_id), tostring(player_id), tostring(event_type))
    return true
end

function CMD.quit_instance(inst_id, player_id)
    log.info("instance.quit request inst_id=%s player=%s", tostring(inst_id), tostring(player_id))
    local inst, ok, err = get_instance_or_error(inst_id)
    if not ok then
        return ok, err
    end

    local scene_data = instance_scene_map[inst_id]
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
        if inst_data and inst_data.type == "multi" then
            log.info("instance.multi_all_quit_complete inst_id=%s", tostring(inst_id))
            inst:complete(false, {
                reason = "all_quit",
                end_type = InstanceEndType.ACTIVE_QUIT,
                end_reason = InstanceEndReason.QUIT_ALL,
            })
        end
        CMD.destroy_instance(inst_id)
    end
    return true
end

function CMD.pause_instance(inst_id)
    local inst, ok, err = get_instance_or_error(inst_id)
    if not ok then
        return ok, err
    end
    local paused = inst:pause()
    if not paused then
        return false, "副本状态不允许暂停"
    end
    return true
end

function CMD.resume_instance(inst_id)
    local inst, ok, err = get_instance_or_error(inst_id)
    if not ok then
        return ok, err
    end
    local resumed = inst:resume()
    if not resumed then
        return false, "副本状态不允许恢复"
    end
    return true
end

function CMD.complete_instance(inst_id, success, data_)
    log.info("instance.complete request inst_id=%s success=%s", tostring(inst_id), tostring(success))
    local inst, ok, err = get_instance_or_error(inst_id)
    if not ok then
        return ok, err
    end
    local completed = inst:complete(success, data_)
    if not completed then
        return false, "副本状态不允许结束"
    end
    return true
end

function CMD.get_instance_status(inst_id)
    local inst, ok, err = get_instance_or_error(inst_id)
    if not ok then
        return ok, err
    end
    return true, inst:get_status()
end

function CMD.get_instance_info(inst_id)
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
        scene_id = instance_scene_map[inst_id] and instance_scene_map[inst_id].scene_id or 0,
        join_count = tableUtils.table_size(inst.pjoins_),
        enter_count = tableUtils.table_size(inst.penters_),
    }
end

function CMD.list_instances()
    local list = {}
    for inst_id, data in pairs(instance_mgr.instances) do
        list[inst_id] = {
            type = data.type,
            create_time = data.create_time,
            status = data.inst and data.inst:get_status() or 0,
            scene_id = instance_scene_map[inst_id] and instance_scene_map[inst_id].scene_id or 0,
        }
    end
    return true, list
end

function CMD.get_player_instance(player_id)
    return instance_mgr.get_player_instance(player_id)
end

function CMD.get_player_flow(player_id)
    local flow = get_agent_flow(player_id)
    if not flow then
        return false, "获取玩家流程态失败"
    end
    return true, flow
end

function CMD.try_enter_match_flow(player_id)
    local in_inst = instance_mgr.get_player_instance(player_id)
    if in_inst then
        return false, "玩家已在副本中"
    end
    local ok, err_or_state = protocol_handler.call_agent(player_id, "try_set_player_flow", {
        player_id = player_id,
        expected_states = { "idle" },
        new_state = "matching",
        reason = "match_start",
    })
    if not ok then
        return false, err_or_state or "玩家当前状态不可进入匹配"
    end
    log.info("instance.flow set player=%s flow=matching", tostring(player_id))
    return true
end

function CMD.mark_pending_confirm(player_ids)
    for _, player_id in ipairs(player_ids or {}) do
        local ok = protocol_handler.call_agent(player_id, "try_set_player_flow", {
            player_id = player_id,
            expected_states = { "matching", "pending_confirm" },
            new_state = "pending_confirm",
            reason = "match_pending_confirm",
        })
        if ok then
            log.info("instance.flow set player=%s flow=pending_confirm", tostring(player_id))
        end
    end
    return true
end

function CMD.clear_match_flow(player_ids)
    for _, player_id in ipairs(player_ids or {}) do
        local ok = protocol_handler.call_agent(player_id, "try_set_player_flow", {
            player_id = player_id,
            expected_states = { "matching", "pending_confirm" },
            new_state = "idle",
            reason = "match_flow_clear",
        })
        if ok then
            log.info("instance.flow set player=%s flow=idle", tostring(player_id))
        end
    end
    return true
end

function CMD.sync_player_instance_state(player_id)
    local in_inst, inst_id_or_err = instance_mgr.get_player_instance(player_id)
    if not in_inst then
        return true
    end
    local inst_id = inst_id_or_err
    local inst = instance_mgr.get_instance(inst_id)
    if not inst then
        log.warning("instance.sync_state skip player=%s inst_id=%s reason=inst_missing", tostring(player_id), tostring(inst_id))
        return true
    end
    if not inst:has_player(player_id) then
        log.warning("instance.sync_state skip player=%s inst_id=%s reason=not_member", tostring(player_id), tostring(inst_id))
        return true
    end
    if inst.pack_data_to_client then
        protocol_handler.send_to_player(player_id, "instance_play_data_notify", {
            inst_id = inst_id,
            data = inst:pack_data_to_client(),
        })
    end
    return true
end

function CMD.shutdown()
    running = false

    local scene = skynet.localname(".scene")
    if scene then
        for _, data in pairs(instance_scene_map) do
            skynet.call(scene, "lua", "destroy_scene", data.scene_id)
        end
    end

    instance_scene_map = {}
    instance_mgr.shutdown()
    return true
end

local function main()
    CMD.init()
end

service_wrapper.create_service(main, {
    name = "instance",
})
