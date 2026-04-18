local default_adapter = require "match.adapters.instance_default_adapter"

local adapter = {}

-- 日常副本模板：
-- 1) 可在这里追加玩家活跃度、当日次数等画像字段；
-- 2) 可在 validate_candidate 里校验进入资格；
-- 3) 全员确认后默认沿用“创建并进入副本”逻辑。

function adapter.build_player_profile(player_id, options)
    local profile = default_adapter.build_player_profile(player_id, options) or {}
    profile.daily_score = 0
    profile.daily_enter_count = 0
    return profile
end

function adapter.validate_candidate(profiles, _options)
    for _, profile in ipairs(profiles or {}) do
        -- 模板：可按业务要求改成真实校验
        if profile and profile.daily_enter_count and profile.daily_enter_count < 0 then
            return false, "日常副本次数异常"
        end
    end
    return true
end

function adapter.on_all_confirmed(players, options)
    return default_adapter.on_all_confirmed(players, options)
end

return adapter
