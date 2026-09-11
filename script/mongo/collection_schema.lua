-- Mongo collection 索引注册表。
-- 只描述 collection 名和索引，不描述字段类型（文档库按实际写入演化）。
-- 启动时 mongoS 会 ensure_indexes；业务侧不要把玩家账务表迁到这里。

local schema = {
    -- 地图世界权威冷库：公共物品 / 公共怪 / 图级 meta。
    -- 热路径仍在 map/scene 内存；玩家进度不进这里。
    ["map_entity"] = {
        indexes = {
            {
                name = "idx_map_chunk_type",
                keys = {
                    { map_id = 1 },
                    { chunk_id = 1 },
                    { type = 1 },
                },
            },
            {
                name = "idx_map_owner",
                keys = {
                    { map_id = 1 },
                    { owner_id = 1 },
                },
            },
            {
                name = "idx_map_alliance",
                keys = {
                    { map_id = 1 },
                    { alliance_id = 1 },
                },
                sparse = true,
            },
        },
    },
}

return schema
