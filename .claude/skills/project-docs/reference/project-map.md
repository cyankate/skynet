# 代码 → 文档映射（project map）

维护文档时同步更新本文件。改了哪些文件，就对照这张表定位要更新的文档。

## 代码 → 文档

| 代码路径 | 对应文档 | 说明 |
|----------|----------|------|
| `script/main.lua`、`script/init*.config`、`script/cluster/*`、`script/entry/*`（启动相关） | `docs/architecture.md`、`docs/dev-guide.md`、`script/cluster/README.md` | 进程/服务拓扑、启动顺序、cluster 拆分 |
| `script/service/*_service.lua` | `docs/services.md`（目录）+ `docs/gameplay.md`（玩法） | 每个服务一行 |
| `script/protocol/`、`script/net/`、`script/protoloader.lua`、`script/utils/proto_builder.lua` | `docs/protocol.md` | 协议定义、加载、C2S 入口 |
| `script/map/*`、`service/map_service.lua`、`shard_service.lua`、`pathfinding_service.lua` | `script/map/README.md`（权威）、`docs/architecture.md`（概述） | 大地图框架 |
| `script/scene/*`、`script/instance/*`、`script/match/*` | `docs/gameplay.md` | 副本/场景/匹配 |
| `script/system/*`、`script/player_obj.lua`、`script/ctn/*`、`script/effect/*`、`script/define/*`、`script/setting/*` | `docs/gameplay.md` | 养成/玩法系统 |
| `script/sql/*`、`script/mongo/*`、`script/cache/*`、`db_service`/`redis_service`/`mongo_service` | `docs/storage.md` | 持久化 |
| `script/security/*` | `script/security/README.md`（已有）、`docs/services.md`（一行） | 安全/支付/加密 |

## 服务速查（入口 → service → 核心模块）

- `gate .gate.N`：`entry/gateS.lua` → `service/gate_service.lua`（snax.gateserver，embed 模式）—— 客户端连接入口，收 C2S、下行直推。
- `login .login`：`entry/loginS.lua` → `service/login_service.lua` —— 登录、账号加载、agent 池。
- `agent`（每玩家一个，非 named）：`entry/agentS.lua` → `service/agent_service.lua` —— 玩家会话，持有 `player_obj` + ctn 容器。
- `locator .locator`：`entry/locatorS.lua` → `service/locator_service.lua` —— 在线目录 `player_id → {gate, node, agent}`。
- `db .db`：`service/db_service.lua` —— MySQL（`sql/table_schema.lua`、`sql/all.sql`）。
- `redis .redis`：`service/redis_service.lua` —— Redis 连接池。
- `mongo .mongo`：`service/mongo_service.lua` —— MongoDB（`mongo/collection_schema.lua`）。
- `http .http`：`service/http_service.lua` —— GM / HTTP 接口，端口 8889。
- `protoloader .protoloader`：`script/protoloader.lua` —— 加载 sproto c2s/s2c schema。
- 基础设施：`event`、`security`、`hotfix`、`logger`（`entry/loggerS.lua`）。
- `map .map.<id>`：`service/map_service.lua` —— 全图全局服（注册表 + 派生状态，非热路径）。
- `shard .shard.<map>.<sid>`：`service/shard_service.lua` —— 分片（权威实体 + AOI + 行军 tick）。
- `pathfinding .pathfinding`：`service/pathfinding_service.lua` —— 全图 A* 导航、主城占格。
- `match .match`：`service/match_service.lua` —— 匹配队列（matching → pending_confirm）。
- `instance .instance`：`service/instance_service.lua` —— 副本实例管理。
- `scene`：`service/scene_service.lua` —— 实例内场景（entity / grid_aoi / monster / ai）。
- 玩法系统服务：`chat` / `friend` / `guild` / `mail` / `rank` / `season` / `payment` / `global` —— 各 `system/*_mgr` 的对外入口。

## 关键背景事实（写文档时引用，避免每次重翻代码）

- 引擎是 skynet（Lua actor 模型）；`3rd` 是 jemalloc / lpeg / lua-cjson / lua-md5 / luasocket / recastnavigation。
- 每个服务一个独立 Lua VM。`utils/service_wrapper.lua` 统一：分发 `_G.CMD`、注册 `.name`、`rpc.export`、接入热更新、统计耗时。
- 服务状态用 `runtime/service_ctx.lua` 的 `service_ctx.get(key)` 存进 `_G` registry，热更新时能保留内存状态。
- 协议用 sproto（`sprotoloader`），协议号在 `protocol/proto.lua`，schema 构建在 `utils/proto_builder.lua`。
- 三种运行模式 `cluster_mode = standalone / loopback / split`，见 `script/cluster/README.md`。
- C2S 入口在 `script/net/*_net.lua`（挂在玩家/agent 上）；下行统一走 `protocol_handler.send_to_player`（经 agent）/ `send_to_conn`（分片直推门）。
- 大地图（map/shard）与副本场景（scene/instance）是**两套空间框架**，不要混。
- 端口：gate 8888（单进程直连）/ 19001·19002（nginx 后，客户端 8000）；http 8889；debug game 8890、map1 8891、map2 8892；cluster 2528/2529/2530。
