-- 地图配置（测试数据）
-- key：地图 id

return {
    [101] = {
        id = 101,
        name = "村外草地11",
        chapter_id = 1,
        scene_res = "scene_grass_01",
        bgm = "bgm_field_peace",
        width = 2048,
        height = 1536,
        spawn_player = { x = 120, y = 400 },
        exit_portal = { x = 1900, y = 400 },
        monster_groups = {
            { mob_id = 5001, count = 3, zone = { x = 600, y = 350, w = 400, h = 200 } },
            { mob_id = 5002, count = 1, zone = { x = 1400, y = 320, w = 300, h = 200 } },
        },
    },
    [102] = {
        id = 102,
        name = "幽暗小径33",
        chapter_id = 2,
        scene_res = "scene_forest_night",
        bgm = "bgm_forest_amb",
        width = 2560,
        height = 1536,
        spawn_player = { x = 820, y = 500 },
        exit_portal = { x = 240, y = 480 },
        monster_groups = {
            { mob_id = 5010, count = 4, zone = { x = 700, y = 400, w = 500, h = 250 } },
            { mob_id = 5011, count = 2, zone = { x = 1600, y = 380, w = 450, h = 220 } },
        },
    },
    [103] = {
        id = 103,
        name = "废弃矿洞222一层",
        chapter_id = 3,
        scene_res = "scene_cave_mine",
        bgm = "bgm_cave_drip",
        width = 3072,
        height = 1728,
        spawn_player = { x = 200, y = 800 },
        exit_portal = { x = 2800, y = 750 },
        monster_groups = {
            { mob_id = 5020, count = 5, zone = { x = 900, y = 600, w = 600, h = 300 } },
            { mob_id = 5021, count = 3, zone = { x = 2000, y = 580, w = 550, h = 280 } },
            { mob_id = 5025, count = 1, zone = { x = 2500, y = 550, w = 200, h = 200 }, boss = true },
        },
    },
}
