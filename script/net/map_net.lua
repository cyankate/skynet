local skynet = require "skynet"
local user_mgr = require "user_mgr"
local protocol_handler = require "protocol_handler"
local shard = require "map.shard"

local function remember(player, result)
    if player and type(result) == "table" then
        if result.map_id then
            player.map_id_ = result.map_id
        end
        if result.shard_id ~= nil then
            player.map_shard_id_ = result.shard_id
        end
    end
end

local function forget(player)
    if player then
        player.map_id_ = nil
        player.map_shard_id_ = nil
        player.march_shards_ = nil
        player.city_shard_id_ = nil
    end
end

local function remember_march(player, result)
    if not player or type(result) ~= "table" then
        return
    end
    player.march_shards_ = player.march_shards_ or {}
    if result.march_uid and result.march_uid ~= "" and result.shard_id ~= nil then
        player.march_shards_[tostring(result.march_uid)] = result.shard_id
    end
    if result.removed and result.march_uid then
        player.march_shards_[tostring(result.march_uid)] = nil
    end
    if type(result.marches) == "table" then
        for _, m in ipairs(result.marches) do
            if m.uid and m.shard_id ~= nil then
                player.march_shards_[tostring(m.uid)] = m.shard_id
            end
        end
    end
end

local function call_march_map(player, player_id, march_uid, cmd, ...)
    march_uid = tostring(march_uid or "")
    local args = { ... }
    local tried = {}
    local function try_sid(sid)
        if sid == nil or tried[sid] then
            return nil
        end
        tried[sid] = true
        local addr = shard_addr((player and player.map_id_) or shard.DEFAULT_MAP_ID, sid)
        if not addr then
            return nil
        end
        local ok, result = skynet.call(addr, "lua", cmd, player_id, table.unpack(args))
        if not (ok == false and (result == "march not found" or result == "player not in map" or result == "map not found")) then
            return ok, result
        end
        return nil
    end
    local cached = player and player.march_shards_ and player.march_shards_[march_uid]
    local ok, result = try_sid(cached)
    if ok ~= nil then
        return ok, result
    end
    ok, result = try_sid(player and player.map_shard_id_)
    if ok ~= nil then
        return ok, result
    end
    for _, sid in ipairs(shard.all_ids()) do
        ok, result = try_sid(sid)
        if ok ~= nil then
            return ok, result
        end
    end
    return false, "march not found"
end

local function shard_addr(map_id, shard_id)
    return skynet.localname(shard.service_name(map_id, shard_id))
end

local function player_map_addr(player)
    if not player or player.map_shard_id_ == nil then
        return nil
    end
    return shard_addr(player.map_id_ or shard.DEFAULT_MAP_ID, player.map_shard_id_)
end

local function call_player_map(player, player_id, cmd, ...)
    local addr = player_map_addr(player)
    if addr then
        local ok, result = skynet.call(addr, "lua", cmd, player_id, ...)
        if not (ok == false and result == "player not in map") then
            return ok, result
        end
    end
    for _, sid in ipairs(shard.all_ids()) do
        local a = shard_addr(shard.DEFAULT_MAP_ID, sid)
        if a and a ~= addr then
            local ok, result = skynet.call(a, "lua", cmd, player_id, ...)
            if not (ok == false and result == "player not in map") then
                return ok, result
            end
        end
    end
    return false, "player not in map"
end

local function leave_all(player, player_id)
    for _, sid in ipairs(shard.all_ids()) do
        local a = shard_addr((player and player.map_id_) or shard.DEFAULT_MAP_ID, sid)
        if a then
            pcall(skynet.call, a, "lua", "leave_map", player_id)
        end
    end
    forget(player)
end

local function on_map_list(player_id, msg)
    local def = shard.default_def()
    protocol_handler.send_to_player(player_id, "map_list_response", {
        result = 0,
        message = "ok",
        maps = {
            {
                map_id = def.map_id,
                name = def.name,
            },
        },
    })
    return true
end

local function on_map_enter(player_id, msg)
    local player = user_mgr.get_player_obj(player_id)
    local def = shard.default_def()
    local start = def.start or {}
    local sid = shard.shard_id_of_pos(start.x or 1, start.y or 1, def)
    leave_all(player, player_id)
    local addr = shard_addr(def.map_id, sid)
    if not addr then
        protocol_handler.send_to_player(player_id, "map_enter_response", {
            result = 1,
            message = "地图服务不可用",
            map_id = def.map_id,
            scene_id = 0,
            x = 0,
            y = 0,
        })
        return false, "Map service not available"
    end
    local player_name = player and player.player_name_ or ""
    local ok, result = skynet.call(addr, "lua", "enter_map", player_id, player_name, def.map_id)
    if not ok then
        protocol_handler.send_to_player(player_id, "map_enter_response", {
            result = 1,
            message = result or "进入地图失败",
            map_id = def.map_id,
            scene_id = 0,
            x = 0,
            y = 0,
        })
        return false, result
    end
    remember(player, result)
    -- 进图落在主城所在片：记下供行军路由（主城不迁移，一次缓存长期有效）
    player.city_shard_id_ = result.shard_id or sid
    protocol_handler.send_to_player(player_id, "map_enter_response", {
        result = 0,
        message = "ok",
        map_id = result.map_id,
        scene_id = result.scene_id,
        x = result.x,
        y = result.y,
    })
    protocol_handler.send_to_player(player_id, "main_scene_enter_notify", {
        scene_id = result.scene_id or 0,
        x = result.x or 0,
        y = result.y or 0,
    })
    return true
end

local function on_map_move(player_id, msg)
    local player = user_mgr.get_player_obj(player_id)
    local old_sid = player and player.map_shard_id_
    local ok, result = call_player_map(player, player_id, "move", tonumber(msg and msg.x) or 0, tonumber(msg and msg.y) or 0)
    if not ok then
        protocol_handler.send_to_player(player_id, "map_move_response", {
            result = 1,
            message = result or "移动失败",
            map_id = player and player.map_id_ or 0,
            x = 0,
            y = 0,
        })
        return false, result
    end
    remember(player, result)
    if result.shard_id ~= nil and result.shard_id ~= old_sid then
        local addr = player_map_addr(player)
        if addr then
            pcall(skynet.call, addr, "lua", "sync_player_view", player_id)
        end
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
    local player = user_mgr.get_player_obj(player_id)
    local monster_uid = tostring(msg and msg.monster_uid or "")
    local city_sid = player and player.city_shard_id_
    local city_addr = city_sid ~= nil
        and shard_addr((player and player.map_id_) or shard.DEFAULT_MAP_ID, city_sid)
        or nil
    local ok, result
    if city_addr then
        ok, result = skynet.call(city_addr, "lua", "interact_monster", player_id, monster_uid)
    end
    if ok == nil then
        ok, result = call_player_map(player, player_id, "interact_monster", monster_uid)
    end
    if not ok then
        protocol_handler.send_to_player(player_id, "map_interact_monster_response", {
            result = 1,
            message = result or "交互失败",
            map_id = player and player.map_id_ or 0,
            monster_uid = monster_uid,
            battle_type = "",
            accepted = false,
            march_uid = "",
            state = "",
        })
        return false, result
    end
    remember(player, result)
    remember_march(player, result)
    protocol_handler.send_to_player(player_id, "map_interact_monster_response", {
        result = 0,
        message = "ok",
        map_id = result.map_id or 0,
        monster_uid = result.monster_uid or monster_uid,
        battle_type = result.battle_type or "march",
        inst_id = result.inst_id or "",
        scene_id = result.scene_id or 0,
        accepted = true,
        march_uid = result.march_uid or "",
        state = result.state or "",
    })
    return true
end

local function on_map_battle_result(player_id, msg)
    local player = user_mgr.get_player_obj(player_id)
    local ok, result = call_player_map(
        player,
        player_id,
        "on_battle_result",
        msg and msg.monster_uid,
        (msg and msg.win) and true or false
    )
    if not ok then
        protocol_handler.send_to_player(player_id, "map_battle_result_response", {
            result = 1,
            message = result or "战斗结果回写失败",
            map_id = player and player.map_id_ or 0,
            monster_uid = tostring(msg and msg.monster_uid or ""),
            win = (msg and msg.win) and true or false,
            removed = false,
        })
        return false, result
    end
    remember(player, result)
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
    local player = user_mgr.get_player_obj(player_id)
    local ok, result = call_player_map(player, player_id, "pick_item", msg and msg.item_uid)
    if not ok then
        protocol_handler.send_to_player(player_id, "map_pick_item_response", {
            result = 1,
            message = result or "拾取失败",
            map_id = player and player.map_id_ or 0,
            item_uid = tostring(msg and msg.item_uid or ""),
            item_id = 0,
            count = 0,
            removed = false,
        })
        return false, result
    end
    remember(player, result)
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
    local player = user_mgr.get_player_obj(player_id)
    local addr = player_map_addr(player)
    local result
    if addr then
        result = skynet.call(addr, "lua", "get_state", player_id)
    end
    if not result or (result.map_id or 0) <= 0 then
        for _, sid in ipairs(shard.all_ids()) do
            local a = shard_addr(shard.DEFAULT_MAP_ID, sid)
            if a and a ~= addr then
                local st = skynet.call(a, "lua", "get_state", player_id)
                if st and (st.map_id or 0) > 0 then
                    result = st
                    remember(player, st)
                    break
                end
            end
        end
    end
    result = result or {
        map_id = 0,
        scene_id = 0,
        x = 0,
        y = 0,
        monsters = {},
        resources = {},
        marches = {},
        buildings = {},
    }
    protocol_handler.send_to_player(player_id, "map_state_response", {
        result = 0,
        message = "ok",
        map_id = result.map_id,
        scene_id = result.scene_id,
        x = result.x,
        y = result.y,
        monsters = result.monsters,
        resources = result.resources,
        marches = result.marches or {},
        buildings = result.buildings or {},
    })
    return true
end

local function on_map_leave(player_id, msg)
    local player = user_mgr.get_player_obj(player_id)
    leave_all(player, player_id)
    protocol_handler.send_to_player(player_id, "map_leave_response", {
        result = 0,
        message = "ok",
        map_id = 0,
    })
    return true
end

local function on_map_march_start(player_id, msg)
    local player = user_mgr.get_player_obj(player_id)
    local dx = tonumber(msg and msg.x) or 0
    local dy = tonumber(msg and msg.y) or 0
    -- 行军从主城出发：优先路由到主城所在片（进图时缓存）
    local city_sid = player and player.city_shard_id_
    local city_addr = city_sid ~= nil
        and shard_addr((player and player.map_id_) or shard.DEFAULT_MAP_ID, city_sid)
        or nil
    local ok, result
    if city_addr then
        ok, result = skynet.call(city_addr, "lua", "march_start", player_id, dx, dy)
    end
    if ok == nil then
        ok, result = call_player_map(player, player_id, "march_start", dx, dy)
    end
    if not ok then
        protocol_handler.send_to_player(player_id, "map_march_start_response", {
            result = 1,
            message = result or "出发失败",
            march_uid = "",
            x = 0,
            y = 0,
            dest_x = tonumber(msg and msg.x) or 0,
            dest_y = tonumber(msg and msg.y) or 0,
            hp = 0,
            max_hp = 0,
            state = "",
        })
        return false, result
    end
    remember(player, result)
    remember_march(player, result)
    protocol_handler.send_to_player(player_id, "map_march_start_response", {
        result = 0,
        message = "ok",
        march_uid = result.march_uid or "",
        x = result.x or 0,
        y = result.y or 0,
        dest_x = result.dest_x or 0,
        dest_y = result.dest_y or 0,
        hp = result.hp or 0,
        max_hp = result.max_hp or 0,
        state = result.state or "",
    })
    return true
end

local function on_map_march_attack(player_id, msg)
    local player = user_mgr.get_player_obj(player_id)
    local march_uid = tostring(msg and msg.march_uid or "")
    local target_uid = tostring(msg and msg.target_uid or "")
    local ok, result = call_march_map(player, player_id, march_uid, "march_attack", march_uid, target_uid)
    if not ok then
        protocol_handler.send_to_player(player_id, "map_march_attack_response", {
            result = 1,
            message = result or "追击失败",
            march_uid = march_uid,
            target_uid = target_uid,
            state = "",
            battle_id = "",
        })
        return false, result
    end
    remember_march(player, result)
    protocol_handler.send_to_player(player_id, "map_march_attack_response", {
        result = 0,
        message = "ok",
        march_uid = result.march_uid or march_uid,
        target_uid = result.target_uid or target_uid,
        state = result.state or "",
        battle_id = result.battle_id or "",
    })
    return true
end

local function on_map_march_cancel(player_id, msg)
    local player = user_mgr.get_player_obj(player_id)
    local march_uid = tostring(msg and msg.march_uid or "")
    local ok, result = call_march_map(player, player_id, march_uid, "march_cancel", march_uid)
    if not ok then
        protocol_handler.send_to_player(player_id, "map_march_cancel_response", {
            result = 1,
            message = result or "取消失败",
            march_uid = march_uid,
            removed = false,
        })
        return false, result
    end
    remember_march(player, result)
    protocol_handler.send_to_player(player_id, "map_march_cancel_response", {
        result = 0,
        message = "ok",
        march_uid = result.march_uid or march_uid,
        removed = result.removed and true or false,
    })
    return true
end

local function on_map_march_gather(player_id, msg)
    local player = user_mgr.get_player_obj(player_id)
    local resource_uid = tostring(msg and msg.resource_uid or "")
    local city_sid = player and player.city_shard_id_
    local city_addr = city_sid ~= nil
        and shard_addr((player and player.map_id_) or shard.DEFAULT_MAP_ID, city_sid)
        or nil
    local ok, result
    if city_addr then
        ok, result = skynet.call(city_addr, "lua", "march_gather", player_id, resource_uid)
    end
    if ok == nil then
        ok, result = call_player_map(player, player_id, "march_gather", resource_uid)
    end
    if not ok then
        protocol_handler.send_to_player(player_id, "map_march_gather_response", {
            result = 1,
            message = result or "采集出发失败",
            march_uid = "",
            resource_uid = resource_uid,
            x = 0,
            y = 0,
            dest_x = 0,
            dest_y = 0,
            hp = 0,
            max_hp = 0,
            state = "",
            intent = "",
        })
        return false, result
    end
    remember(player, result)
    remember_march(player, result)
    protocol_handler.send_to_player(player_id, "map_march_gather_response", {
        result = 0,
        message = "ok",
        march_uid = result.march_uid or "",
        resource_uid = result.resource_uid or resource_uid,
        x = result.x or 0,
        y = result.y or 0,
        dest_x = result.dest_x or 0,
        dest_y = result.dest_y or 0,
        hp = result.hp or 0,
        max_hp = result.max_hp or 0,
        state = result.state or "",
        intent = result.intent or "",
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
    map_march_start = on_map_march_start,
    map_march_attack = on_map_march_attack,
    map_march_cancel = on_map_march_cancel,
    map_march_gather = on_map_march_gather,
}
