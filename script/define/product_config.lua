-- 游戏内商品配置
-- 包含各种可购买物品的定义

local products = {
    -- 钻石商品
    {
        id = "com.game.diamond.60",
        name = "60钻石",
        type = "diamond",
        amount = 6.00,
        currency = "CNY",
        description = "购买60钻石",
        icon = "diamond_1",
        diamond = 60,
        bonus = 0,
        tag = "",
        sort_order = 1,
    },
    {
        id = "com.game.diamond.300",
        name = "300钻石",
        type = "diamond",
        amount = 30.00,
        currency = "CNY",
        description = "购买300钻石",
        icon = "diamond_2",
        diamond = 300,
        bonus = 30,
        tag = "",
        sort_order = 2,
    },
    {
        id = "com.game.diamond.980",
        name = "980钻石",
        type = "diamond",
        amount = 98.00,
        currency = "CNY",
        description = "购买980钻石",
        icon = "diamond_3",
        diamond = 980,
        bonus = 98,
        tag = "",
        sort_order = 3,
    },
    {
        id = "com.game.diamond.1980",
        name = "1980钻石",
        type = "diamond",
        amount = 198.00,
        currency = "CNY",
        description = "购买1980钻石",
        icon = "diamond_4",
        diamond = 1980,
        bonus = 298,
        tag = "推荐",
        sort_order = 4,
    },
    {
        id = "com.game.diamond.3280",
        name = "3280钻石",
        type = "diamond",
        amount = 328.00,
        currency = "CNY",
        description = "购买3280钻石",
        icon = "diamond_5",
        diamond = 3280,
        bonus = 656,
        tag = "超值",
        sort_order = 5,
    },
    {
        id = "com.game.diamond.6480",
        name = "6480钻石",
        type = "diamond",
        amount = 648.00,
        currency = "CNY",
        description = "购买6480钻石",
        icon = "diamond_6",
        diamond = 6480,
        bonus = 1498,
        tag = "史诗",
        sort_order = 6,
    },
    
    -- 月卡商品
    {
        id = "com.game.card.month",
        name = "月卡",
        type = "card",
        amount = 30.00,
        currency = "CNY",
        description = "购买月卡，立即获得300钻石，并在30天内每天获得100钻石",
        icon = "month_card",
        diamond = 300,
        daily_diamond = 100,
        duration = 30,
        tag = "超值",
        sort_order = 101,
    },
    
    -- 礼包商品
    {
        id = "com.game.gift.beginner",
        name = "新手礼包",
        type = "gift",
        amount = 18.00,
        currency = "CNY",
        description = "新手专属礼包，包含300钻石、10万金币和稀有装备",
        icon = "gift_beginner",
        items = {
            {id = "diamond", count = 300},
            {id = "gold", count = 100000},
            {id = "equip_101", count = 1},
        },
        limit = 1, -- 限购1次
        tag = "限时",
        sort_order = 201,
    },
    {
        id = "com.game.gift.advanced",
        name = "进阶礼包",
        type = "gift",
        amount = 68.00,
        currency = "CNY",
        description = "进阶玩家推荐礼包，包含1000钻石、50万金币和多种稀有资源",
        icon = "gift_advanced",
        items = {
            {id = "diamond", count = 1000},
            {id = "gold", count = 500000},
            {id = "energy", count = 100},
            {id = "material_301", count = 10},
            {id = "material_302", count = 5},
        },
        limit = 3, -- 限购3次
        tag = "热卖",
        sort_order = 202,
    },
    
    -- 特惠商品
    {
        id = "com.game.special.first_recharge",
        name = "首充特惠",
        type = "special",
        amount = 6.00,
        currency = "CNY",
        description = "首次充值特惠，获得双倍钻石和稀有装备",
        icon = "special_first",
        items = {
            {id = "diamond", count = 120}, -- 双倍钻石
            {id = "gold", count = 50000},
            {id = "equip_201", count = 1},
        },
        condition = "first_recharge", -- 首充限定
        tag = "限时",
        sort_order = 301,
    },
    
    -- VIP商品
    {
        id = "com.game.vip.forever",
        name = "永久VIP",
        type = "vip",
        amount = 198.00,
        currency = "CNY",
        description = "解锁永久VIP特权，享受商城折扣和专属功能",
        icon = "vip_forever",
        vip_level = 1,
        duration = -1, -- 永久
        tag = "尊贵",
        sort_order = 401,
    },
}

return products