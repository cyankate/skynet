return {
    level = {
        id = "level",
        name = "等级榜",
        sort_key = "level",
        max_display = 100,
        refresh_cron = "0 5 * * *",
        settle_reward = true,
    },
    power = {
        id = "power",
        name = "战力榜",
        sort_key = "combat_power",
        max_display = 100,
        refresh_cron = "0 5 * * *",
        settle_reward = true,
    },
}