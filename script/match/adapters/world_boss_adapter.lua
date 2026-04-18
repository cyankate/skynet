local default_adapter = require "match.adapters.instance_default_adapter"

local adapter = {}

-- 世界Boss模板：
-- 1) build_player_profile 可读取战力、职业、阵营等世界Boss专属数据；
-- 2) validate_candidate 可做跨队伍约束（阵营、最低战力、角色互斥）；
-- 3) on_all_confirmed 可改成进入世界Boss专属场景/UI，而非普通副本。

function adapter.build_player_profile(player_id, options)
    local profile = default_adapter.build_player_profile(player_id, options) or {}
    profile.power = 0
    profile.camp = "neutral"
    profile.boss_buff_level = 0
    return profile
end

function adapter.validate_candidate(profiles, _options)
    for _, profile in ipairs(profiles or {}) do
        -- 模板：可替换为世界Boss入场门槛校验
        if profile and profile.power and profile.power < 0 then
            return false, "世界Boss匹配玩家战力异常"
        end
    end
    return true
end

function adapter.on_all_confirmed(players, options)
    -- 模板默认复用副本落地，后续可改成特殊界面/战斗服务入口
    return default_adapter.on_all_confirmed(players, options)
end

return adapter
