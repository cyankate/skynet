# 服务目录

按职责分组。入口都在 `script/entry/`（薄壳），逻辑在 `script/service/`。带 `.名字` 的是全局可寻址服务（`skynet.name` + `cluster` 登记），`agent` 是每玩家一个、不登记的会话服务。

## 连接与登录

### gate（`.gate.N`）

客户端 TCP 连接入口：收 C2S 包、下行直推。

- 入口：`script/entry/gateS.lua` → `script/service/gate_service.lua`（`snax.gateserver`，embed 模式，自己 `rpc.export`）
- 多门在 game 进程内加服务；`gate_count=1` 直连 8888，双门走 nginx（`gate_behind_lb=1`，听 19001/19002）

### login（`.login`）

登录流程、账号加载、agent 池。

- 入口：`entry/loginS.lua` → `service/login_service.lua`
- 关键状态：`account_loading` / `account_info` / `agent_pool`

### agent（每玩家一个，非 named）

玩家会话服务：持有 `player_obj` 和 ctn 容器（背包 `ctn_bag`、任务 `ctn_task`、条件 `ctn_condition`、日常 `ctn_day`、周常 `ctn_week`）。

- 入口：`entry/agentS.lua` → `service/agent_service.lua`

### locator（`.locator`）

在线目录 `player_id → { gate, node, agent }`。gate 随连接变，agent 跟逻辑进程（闪断宽限期内仍在）。支持顶号 kick、换门时通知所有分片清门缓存。

- 入口：`entry/locatorS.lua` → `service/locator_service.lua`
- 客户端封装：`cluster/locator.lua`（业务不要 `localname(".locator")`）

## 大地图

### map（`.map.<id>`）

全图全局服务（每张图一个）：只做注册表 + 派生状态（争夺建筑归属、联盟 buff 聚合、全图统计）。权威数据永远在分片，崩溃后可从分片重建。**热路径（移动/视野/战斗）绝不路由进来。**

- 入口：`entry/mapS.lua` → `service/map_service.lua`

### shard（`.shard.<map>.<sid>`）

分片服务：本矩形内的权威实体 + 贴边 ghost + 观察者 + 行军/野战/采集 tick。CMD 只做对外入口，转发到 `map/*` 模块。

- 入口：`entry/shardS.lua` → `service/shard_service.lua`
- 核心模块：`map/map.lua`、`map/map_aoi.lua`、`map/view_sync.lua`、`map/march_*.lua`、`map/monster_ai.lua`、`map/interact.lua`、`map/map_store.lua`

### pathfinding（`.pathfinding`）

全图一份 A* 导航；主城占格（圆形障碍）登记在这里，行军 `find_map_path` 都问它。

- 入口：`entry/pathfindingS.lua` → `service/pathfinding_service.lua` → `map/pathfinding.lua`

## 玩法

### match（`.match`）

匹配队列：matching → pending_confirm → 确认/拒绝/超时。匹配成功进副本。

- 入口：`entry/matchS.lua` → `service/match_service.lua` → `match/match_mgr.lua`、`match/play_rules.lua`

### instance（`.instance`）

副本实例管理（`player_instance_map`、实例类型、结束判定）。

- 入口：`entry/instanceS.lua` → `service/instance_service.lua` → `instance/instance_mgr.lua`

### scene

实例内的场景空间（0.1s tick）：`scene_mgr` 管 `scene_id → scene_obj`，场景内有 entity / grid_aoi / monster / ai / 场景内寻路。

- 入口：`entry/sceneS.lua` → `service/scene_service.lua` → `scene/scene_mgr.lua`

### chat（`.chat`）

频道聊天：world / guild / private 频道 + 限流（`chat/rate_limiter.lua`）。

### friend（`.friend`）

好友系统。→ `system/friend/friend_mgr.lua`

### guild（`.guild`）

联盟/公会。→ `system/guild/guild_mgr.lua`

### mail（`.mail`）

邮件。→ `system/mail/mail_mgr.lua`

### rank（`.rank`）

排行榜（分数榜）。→ `system/rank/score_rank.lua`

### season（`.season`）

赛季与阶段推进。→ `define/season_def.lua`

### payment（`.payment`）

支付（alipay / wechat / appstore / google / paypal…），下单、回调校验。→ `security/payment.lua`、`security/encrypt.lua`

### global（`.global`）

全局数据（`global_mgr`：内存缓存 + 定时 flush）。→ `system/global/global_mgr.lua`

## 数据与基础设施

### db（`.db`）

MySQL。→ `service/db_service.lua` + `sql/table_schema.lua`、`sql/all.sql`

### redis（`.redis`）

Redis 连接池。→ `service/redis_service.lua`

### mongo（`.mongo`）

MongoDB。→ `service/mongo_service.lua` + `mongo/collection_schema.lua`

### http（`.http`）

HTTP / GM 接口，端口 8889。→ `service/http_service.lua`

### protoloader（`.protoloader`）

加载 sproto c2s/s2c schema，支持热更协议并通知各门 reload。→ `script/protoloader.lua`

### event / security / hotfix / logger

- `event`：事件订阅分发（`define/event_def.lua`）。
- `security`：加密 / token / 防刷 / 校验（`security/*`，见 [security/README.md](../script/security/README.md)）。
- `hotfix`：热更新调度（`service/hotfix_service.lua`）。
- `logger`：日志（`entry/loggerS.lua` → `service/logger_service.lua`）。
