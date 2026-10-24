# 持久化

三套存储 + 一层进程内缓存。三者的分工以代码为准（`db_service` / `redis_service` / `mongo_service`）。

## 存储服务

| 服务 | 存储 | 关键文件 |
|------|------|----------|
| `db .db` | MySQL | `service/db_service.lua`、`sql/table_schema.lua`、`sql/all.sql`、`sql/migrations/`、`sql/update.sql` |
| `redis .redis` | Redis | `service/redis_service.lua`（连接池） |
| `mongo .mongo` | MongoDB | `service/mongo_service.lua`、`mongo/collection_schema.lua` |

MySQL 表结构在 `sql/table_schema.lua`（自动生成，含字段类型 / 主键 / 注释，例：`account` 表），建表脚本 `all.sql`，变更走 `migrations/` 和 `update.sql`。

## 进程内缓存层（`script/cache/`）

一套基于 `utils/class` 的缓存框架，用 `sql/table_schema.lua` 感知表结构，负责玩家数据的加载、变更落库：

- `base_cache.lua`：`BaseCache` 基类，定义 INSERT/UPDATE 等 DB 操作。
- `player_cache.lua` / `player_cache_item.lua`：玩家数据缓存（默认 `max_size=10000`、`expire_time=3600s`）。
- `friend_cache` / `chat_cache` / `private_cache`（各带 `_cache_item`）：按域拆分的缓存。
- `load_lock.lua`：`LoadLock`，防止同一份数据并发重复加载（`loading` + 等待队列 + 加载超时）。

## ID 生成

`utils/id_generator.lua`（配 `id_generator_config.lua`）：基于位运算的分布式 ID 生成，`db` 服务提供 `gen_id("player")` 等入口（见 `agent_service.lua` 里的 `gen_id` / `create_player`）。

## 落库策略要点

- 大地图：`map/map_store.lua` 只落库「身份和配置」（怪 / 资源 / 主城、建筑等级、资源余量），**不落库**行军路径、交战、巡逻目标点、资源 `occupier_uid`（见 [script/map/README.md](../script/map/README.md)）。
- 全局数据：`system/global/global_mgr.lua` 内存缓存 + 定时 flush（`FLUSH_INTERVAL`）。
