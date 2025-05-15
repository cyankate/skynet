
local bit = require("utils.bit")
local zone_id = 123

local IDGeneratorConfig = {
    -- 邮件ID生成器
    mail = {
        type = "increment",    -- 递增类型
        table = "mail",        -- 对应的数据表
        id_field = "id",       -- ID字段名
        init_value = 1000,     -- 初始值
    },
    
    -- 玩家ID生成器
    player = {
        type = "increment",    -- 递增类型
        table = "player",        -- 对应的数据表
        id_field = "player_id",  -- ID字段名
        init_value = 10000,     -- 初始值
    },

}

return IDGeneratorConfig 