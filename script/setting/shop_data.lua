-- 商店配置（测试数据）
-- tabs：页签；goods：商品列表，key 为商品 id

local M = {}

M.tabs = {
    { id = "daily", name = "每日特惠", sort = 1 },
    { id = "gift", name = "礼包", sort = 2 },
    { id = "black", name = "黑市", sort = 3 },
}

M.goods = {
    [1001] = {
        id = 1001,
        tab = "daily",
        name = "体力小补给",
        item_id = 90001,
        item_count = 60,
        cost_type = "diamond",
        cost = 50,
        buy_limit_per_day = 3,
        sort = 1,
        enabled = true,
    },
    [1002] = {
        id = 1002,
        tab = "daily",
        name = "金币袋",
        item_id = 10001,
        item_count = 5000,
        cost_type = "diamond",
        cost = 30,
        buy_limit_per_day = 5,
        sort = 2,
        enabled = true,
    },
    [2001] = {
        id = 2001,
        tab = "gift",
        name = "新手成长礼包",
        item_id = 0,
        item_count = 0,
        bundle = {
            { item_id = 10001, count = 10000 },
            { item_id = 90001, count = 120 },
            { item_id = 20001, count = 5 },
        },
        cost_type = "rmb_cent",
        cost = 600,
        buy_limit_forever = 1,
        sort = 1,
        enabled = true,
    },
    [3001] = {
        id = 3001,
        tab = "black",
        name = "随机紫装碎片",
        item_id = 31001,
        item_count = 5,
        cost_type = "gold",
        cost = 50000,
        buy_limit_per_week = 2,
        sort = 1,
        enabled = true,
    },
}

return M
