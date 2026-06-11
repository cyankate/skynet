--[[
    天赋表示例：点亮后贡献 effect_ids（展开为 attr_mods 等）。
]]

return {
    [1] = {
        pre_tilents = {},
        cost = {},
        effect_ids = { 1001 },
    },
    [2] = {
        pre_tilents = { 1 },
        cost = {},
        effect_ids = { 1002 },
    },
    [3] = {
        pre_tilents = { 2 },
        cost = {},
        effect_ids = { 1003, 1004 },
    },
}
