local skynet = require "skynet"
local user_mgr = require "user_mgr"
local protocol_handler = require "protocol_handler"
local item_mgr = require "system.item_mgr"
local talent_mgr = require "system.talent_mgr"
local effect_mgr = require "system.effect_mgr"

local function normalize_item_msg(msg)
    if type(msg) ~= "table" then
        return nil, nil, "参数无效"
    end
    local item_id = tonumber(msg.item_id)
    local count = tonumber(msg.count)
    if not item_id or item_id <= 0 then
        return nil, nil, "物品ID无效"
    end
    if not count or count <= 0 then
        return nil, nil, "数量必须大于0"
    end
    count = math.floor(count)
    if count <= 0 then
        return nil, nil, "数量必须大于0"
    end
    return item_id, count
end

local function on_add_item(player_id, msg)
    local player = user_mgr.get_player_obj(player_id)
    if not player then
        return false, "Player not found"
    end
    local item_id, count, err = normalize_item_msg(msg)
    if not item_id then
        return false, err
    end
    local ok, result_or_err = item_mgr.add_items(player, {
        [item_id] = count,
    }, "c2s_add_item")
    if not ok then
        return false, result_or_err
    end
    return true
end

local function on_cost_item(player_id, msg)
    local player = user_mgr.get_player_obj(player_id)
    if not player then
        return false, "Player not found"
    end
    local item_id, count, err = normalize_item_msg(msg)
    if not item_id then
        return false, err
    end
    local ok, result_or_err = item_mgr.cost_items(player, {
        [item_id] = count,
    }, "c2s_cost_item")
    if not ok then
        return false, result_or_err
    end
    return true
end

local function on_change_name(player_id, msg)
    local player = user_mgr.get_player_obj(player_id)
    if not player then
        return false, "Player not found"
    end
    player:change_name(msg.name)
    return true
end

local function on_signin(player_id, msg)
    local player = user_mgr.get_player_obj(player_id)
    if not player then
        return false, "Player not found"
    end
    player:signin()
    return true
end

local function on_add_score(player_id, msg)
    local player = user_mgr.get_player_obj(player_id)
    if not player then
        return false, "Player not found"
    end
    player:add_score(msg.score)
    local score = player:get_score()
    local rankS = skynet.localname(".rank")
    skynet.send(rankS, "lua", "update_rank", "score", {
        player_id = player.player_id_,
        score = score,
    })
    return true
end

local function on_talent_activate(player_id, msg)
    local player = user_mgr.get_player_obj(player_id)
    if not player then
        protocol_handler.send_to_player(player_id, "talent_activate_response", {
            result = 1,
            message = "Player not found",
            talent_id = tonumber(msg.talent_id) or 0,
            level = 0,
        })
        return false, "Player not found"
    end

    local ok, result_or_err = talent_mgr.activate_talent(player, msg.talent_id)
    if not ok then
        protocol_handler.send_to_player(player_id, "talent_activate_response", {
            result = 1,
            message = result_or_err or "点亮失败",
            talent_id = tonumber(msg.talent_id) or 0,
            level = 0,
        })
        return false, result_or_err
    end

    protocol_handler.send_to_player(player_id, "talent_activate_response", {
        result = 0,
        message = "ok",
        talent_id = result_or_err.talent_id or (tonumber(msg.talent_id) or 0),
        level = result_or_err.level or 1,
    })
    talent_mgr.sync_to_client(player)
    effect_mgr.sync_to_client(player)
    return true
end

return {
    add_item = on_add_item,
    cost_item = on_cost_item,
    change_name = on_change_name,
    signin = on_signin,
    add_score = on_add_score,
    talent_activate = on_talent_activate,
}
