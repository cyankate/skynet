local skynet = require "skynet"

local adapter = {}

local function build_instance_error(stage, err_msg)
    local code = 5200
    if stage == "join" or stage == "precheck" then
        code = 5201
    elseif stage == "enter" then
        code = 5202
    end
    return false, err_msg or "匹配成功但副本编排失败", stage or "create", code
end

function adapter.build_player_profile(player_id, _options)
    return {
        player_id = player_id,
    }
end

function adapter.validate_candidate(_profiles, _options)
    return true
end

function adapter.on_all_confirmed(players, options)
    local instanceS = skynet.localname(".instance")
    if not instanceS then
        return false, "副本服务不可用", "create", 5200
    end

    local instance_type_name = options.instance_type_name or options.type_name or "multi"
    local create_args = {
        inst_no = options.inst_no,
        team_size = options.team_size,
        min_players = options.min_players,
        ready_mode = options.ready_mode,
        scene_config = options.scene_config,
        spawn_x = options.spawn_x,
        spawn_y = options.spawn_y,
        creator_id = players[1],
    }
    local batch_ok, batch_result_or_err, err_info = skynet.call(
        instanceS,
        "lua",
        "create_and_enter_batch",
        instance_type_name,
        create_args,
        players,
        {}
    )
    if batch_ok then
        return true, batch_result_or_err
    end
    local stage = err_info and err_info.stage or "create"
    return build_instance_error(stage, batch_result_or_err)
end

return adapter
