local skynet = require "skynet"
local user_mgr = require "user_mgr"
local protocol_handler = require "protocol_handler"

local function on_map_list(player_id, msg)
    local mapS = skynet.localname(".map")
    if not mapS then
        protocol_handler.send_to_player(player_id, "map_list_response", {
            result = 1,
            message = "地图服务不可用",
            maps = {},
        })
        return false, "Map service not available"
    end
    local list = skynet.call(mapS, "lua", "get_map_list", player_id) or {}
    protocol_handler.send_to_player(player_id, "map_list_response", {
        result = 0,
        message = "ok",
        maps = list,
    })
    return true
end

local function on_map_enter(player_id, msg)
    local mapS = skynet.localname(".map")
    if not mapS then
        protocol_handler.send_to_player(player_id, "map_enter_response", {
            result = 1,
            message = "地图服务不可用",
            map_id = tonumber(msg and msg.map_id) or 0,
            scene_id = 0,
            x = 0,
            y = 0,
            region_id = 0,
        })
        return false, "Map service not available"
    end

    local player = user_mgr.get_player_obj(player_id)
    local player_name = player and player.player_name_ or ""
    local ok, result = skynet.call(mapS, "lua", "enter_map", player_id, player_name, tonumber(msg and msg.map_id) or 0)
    if not ok then
        protocol_handler.send_to_player(player_id, "map_enter_response", {
            result = 1,
            message = result or "进入地图失败",
            map_id = tonumber(msg and msg.map_id) or 0,
            scene_id = 0,
            x = 0,
            y = 0,
            region_id = 0,
        })
        return false, result
    end
    protocol_handler.send_to_player(player_id, "map_enter_response", {
        result = 0,
        message = "ok",
        map_id = result.map_id,
        scene_id = result.scene_id,
        x = result.x,
        y = result.y,
        region_id = result.region_id,
    })
    protocol_handler.send_to_player(player_id, "main_scene_enter_notify", {
        scene_id = result.scene_id or 0,
        x = result.x or 0,
        y = result.y or 0,
    })
    return true
end

local function on_map_move(player_id, msg)
    local mapS = skynet.localname(".map")
    if not mapS then
        protocol_handler.send_to_player(player_id, "map_move_response", {
            result = 1,
            message = "地图服务不可用",
            map_id = 0,
            x = 0,
            y = 0,
        })
        return false, "Map service not available"
    end
    local ok, result = skynet.call(mapS, "lua", "move", player_id, tonumber(msg and msg.x) or 0, tonumber(msg and msg.y) or 0)
    if not ok then
        protocol_handler.send_to_player(player_id, "map_move_response", {
            result = 1,
            message = result or "移动失败",
            map_id = 0,
            x = 0,
            y = 0,
        })
        return false, result
    end
    protocol_handler.send_to_player(player_id, "map_move_response", {
        result = 0,
        message = "ok",
        map_id = result.map_id,
        x = result.x,
        y = result.y,
    })
    return true
end

local function on_map_interact_monster(player_id, msg)
    local mapS = skynet.localname(".map")
    if not mapS then
        protocol_handler.send_to_player(player_id, "map_interact_monster_response", {
            result = 1,
            message = "地图服务不可用",
            map_id = 0,
            monster_uid = tostring(msg and msg.monster_uid or ""),
            battle_type = "",
            accepted = false,
        })
        return false, "Map service not available"
    end
    local ok, result = skynet.call(mapS, "lua", "interact_monster", player_id, msg and msg.monster_uid)
    if not ok then
        protocol_handler.send_to_player(player_id, "map_interact_monster_response", {
            result = 1,
            message = result or "交互失败",
            map_id = 0,
            monster_uid = tostring(msg and msg.monster_uid or ""),
            battle_type = "",
            accepted = false,
        })
        return false, result
    end
    protocol_handler.send_to_player(player_id, "map_interact_monster_response", {
        result = 0,
        message = "ok",
        map_id = result.map_id or 0,
        monster_uid = result.monster_uid or "",
        battle_type = result.battle_type or "monster_instance",
        inst_id = result.inst_id or "",
        scene_id = result.scene_id or 0,
        accepted = true,
    })
    return true
end

local function on_map_battle_result(player_id, msg)
    local mapS = skynet.localname(".map")
    if not mapS then
        protocol_handler.send_to_player(player_id, "map_battle_result_response", {
            result = 1,
            message = "地图服务不可用",
            map_id = 0,
            monster_uid = tostring(msg and msg.monster_uid or ""),
            win = (msg and msg.win) and true or false,
            removed = false,
        })
        return false, "Map service not available"
    end
    local ok, result = skynet.call(
        mapS,
        "lua",
        "on_battle_result",
        player_id,
        msg and msg.monster_uid,
        (msg and msg.win) and true or false
    )
    if not ok then
        protocol_handler.send_to_player(player_id, "map_battle_result_response", {
            result = 1,
            message = result or "战斗结果回写失败",
            map_id = 0,
            monster_uid = tostring(msg and msg.monster_uid or ""),
            win = (msg and msg.win) and true or false,
            removed = false,
        })
        return false, result
    end
    protocol_handler.send_to_player(player_id, "map_battle_result_response", {
        result = 0,
        message = "ok",
        map_id = result.map_id or 0,
        monster_uid = result.monster_uid or tostring(msg and msg.monster_uid or ""),
        win = result.win and true or false,
        removed = result.removed and true or false,
    })
    return true
end

local function on_map_pick_item(player_id, msg)
    local mapS = skynet.localname(".map")
    if not mapS then
        protocol_handler.send_to_player(player_id, "map_pick_item_response", {
            result = 1,
            message = "地图服务不可用",
            map_id = 0,
            item_uid = tostring(msg and msg.item_uid or ""),
            item_id = 0,
            count = 0,
            removed = false,
        })
        return false, "Map service not available"
    end
    local ok, result = skynet.call(mapS, "lua", "pick_item", player_id, msg and msg.item_uid)
    if not ok then
        protocol_handler.send_to_player(player_id, "map_pick_item_response", {
            result = 1,
            message = result or "拾取失败",
            map_id = 0,
            item_uid = tostring(msg and msg.item_uid or ""),
            item_id = 0,
            count = 0,
            removed = false,
        })
        return false, result
    end
    protocol_handler.send_to_player(player_id, "map_pick_item_response", {
        result = 0,
        message = "ok",
        map_id = result.map_id or 0,
        item_uid = result.item_uid or tostring(msg and msg.item_uid or ""),
        item_id = result.item_id or 0,
        count = result.count or 0,
        removed = result.removed and true or false,
    })
    return true
end

local function on_map_state(player_id, msg)
    local mapS = skynet.localname(".map")
    if not mapS then
        protocol_handler.send_to_player(player_id, "map_state_response", {
            result = 1,
            message = "地图服务不可用",
            map_id = 0,
            scene_id = 0,
            region_id = 0,
            x = 0,
            y = 0,
            explored_region_count = 0,
            total_region_count = 0,
            fog_percent = 100,
            monsters = {},
            items = {},
        })
        return false, "Map service not available"
    end
    local result = skynet.call(mapS, "lua", "get_state", player_id)
    protocol_handler.send_to_player(player_id, "map_state_response", {
        result = 0,
        message = "ok",
        map_id = result.map_id,
        scene_id = result.scene_id,
        region_id = result.region_id,
        x = result.x,
        y = result.y,
        explored_region_count = result.explored_region_count,
        total_region_count = result.total_region_count,
        fog_percent = result.fog_percent,
        monsters = result.monsters,
        items = result.items,
    })
    return true
end

local function on_map_leave(player_id, msg)
    local mapS = skynet.localname(".map")
    if not mapS then
        protocol_handler.send_to_player(player_id, "map_leave_response", {
            result = 1,
            message = "地图服务不可用",
            map_id = 0,
        })
        return false, "Map service not available"
    end
    local ok, err = skynet.call(mapS, "lua", "leave_map", player_id)
    if not ok then
        protocol_handler.send_to_player(player_id, "map_leave_response", {
            result = 1,
            message = err or "离开地图失败",
            map_id = 0,
        })
        return false, err
    end
    protocol_handler.send_to_player(player_id, "map_leave_response", {
        result = 0,
        message = "ok",
        map_id = 0,
    })
    return true
end

local function on_map_unlock_region(player_id, msg)
    local mapS = skynet.localname(".map")
    if not mapS then
        protocol_handler.send_to_player(player_id, "map_unlock_region_response", {
            result = 1,
            message = "地图服务不可用",
            map_id = 0,
            region_id = tonumber(msg and msg.region_id) or 0,
            key_count = 0,
        })
        return false, "Map service not available"
    end
    local ok, result = skynet.call(mapS, "lua", "unlock_region", player_id, tonumber(msg and msg.region_id) or 0)
    if not ok then
        protocol_handler.send_to_player(player_id, "map_unlock_region_response", {
            result = 1,
            message = result or "区域解锁失败",
            map_id = 0,
            region_id = tonumber(msg and msg.region_id) or 0,
            key_count = 0,
        })
        return false, result
    end
    protocol_handler.send_to_player(player_id, "map_unlock_region_response", {
        result = 0,
        message = "ok",
        map_id = result.map_id or 0,
        region_id = result.region_id or tonumber(msg and msg.region_id) or 0,
        key_count = result.key_count or 0,
    })
    return true
end

return {
    map_list = on_map_list,
    map_enter = on_map_enter,
    map_move = on_map_move,
    map_interact_monster = on_map_interact_monster,
    map_battle_result = on_map_battle_result,
    map_pick_item = on_map_pick_item,
    map_state = on_map_state,
    map_leave = on_map_leave,
    map_unlock_region = on_map_unlock_region,
}
