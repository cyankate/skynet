# 大地图开发维护清单

设计背景见 [README.md](README.md)。下面是改代码时要对着勾的事项。漏一层就会出现「进了 AOI 但客户端看不见」或「看见了但不更新」。

## 文件职责

| 文件 | 改它当… |
|------|---------|
| `aoi_object.lua` | 类型、字段契约、可见打包、ghost 投影条件 |
| `proto.lua` | `map_*` 协议与 `map_entity_*` / `map_march_info` |
| `view_sync.lua` | 合批桶、可见性过滤、拆包 |
| `map.lua` / `map_aoi.lua` | 进场、移动、同格短路、ghost 收发 |
| `observer.lua` | 进图、镜头移动、跨片、主城 |
| `march.lua` | 行军常量、实体、可见打包 |
| `march_runtime.lua` | 行军索引、AOI、寻路、跨片、tick、出发/取消 |
| `march_gather.lua` | 占点采集、回城交货 |
| `march_battle.lua` | 到点结算、打野、跨片交战 |
| `monster_ai.lua` | 巡逻（运行时，不落库） |
| `interact.lua` | 拾取；旧副本回写。打野入口已转到行军 |
| `map_store.lua` | 持久化 |
| `shard.lua` | 分片几何、服务名 |
| `pathfinding.lua` / `block.lua` | 全局寻路、主城占格 |
| `service/pathfinding_service.lua` | 导航图 + blocker |
| `service/shard_service.lua` | CMD 转发，不写玩法 |
| `service/map_service.lua` | 全图派生状态，不进热路径 |
| `net/map_net.lua` | 客户端路由（行军打到主城所在片） |
| `cluster/layout.lua` | 节点放置、cluster_mode |
| `cluster/rpc.lua` | `.gate` / `.shard.*` 地址；loopback 时 proxy |
| `cluster/clustername.lua` | cluster 节点 IP/端口 |
| `init.config` | 单进程 loopback |
| `init_world.config` / `init_map1.config` / `init_map2.config` | split 三进程 |
| `hotspot_test.lua` | 热点回归 |

## 下发红线

场景里「别人也能看见的东西」禁止：

```lua
protocol_handler.send_to_player(pid, "map_visible_sync_notify", ...)
protocol_handler.send_to_player(pid, "map_visible_delta_notify", ...)
```

也不要在 tick 里对 `observers_around` 手写 for 发包。应调用：

| 意图 | API |
|------|-----|
| 出现 / 消失 / 跨格 | `map:enter_obj` / `leave_obj` / `move_obj` |
| 离散属性（hp、count、state…） | `aoi_object.mark_dirty(obj, field)` + `view_sync.sync_obj_attr_around(map, obj)` |
| 连续坐标流（非行军） | `mark_dirty("x"|"y")` + `view_sync.sync_obj_move_around(map, obj)` |
| 行军计划变更 | `march_runtime.broadcast_plan(map, m)` |
| 进图整表 | `view_sync.sync_full`（observer 模块已调） |

`mark_dirty` 的字段名必须在该类型的 `VISIBLE_FIELDS` 里，否则打包带不出去。`sync_obj_attr_around` 推完会 `clear_dirty`，同一 100ms 窗口多次修改只发最后一次。

属主私有通知（`map_march_sync_notify` 等）可以单发，不能替代 AOI。

客户端必须满足：

- enter = **upsert**
- update 只覆盖 **非 nil** 字段
- 同一视野可能拆成多帧 enter（单包最多 50 条）
- full **只有第一帧**；后续是 delta enter，不是第二次整表覆盖

## 新增实体类型

按顺序改，缺一不可。

### 1. `aoi_object.lua`

- [ ] `TYPE.XXX`
- [ ] `TYPE_FIELDS[TYPE.XXX]`：AOI / ghost 需要的字段
- [ ] `VISIBLE_FIELDS[TYPE.XXX]`：打给客户端的字段（含 `uid`）
- [ ] `VISIBLE_BUCKET[TYPE.XXX]`：内部桶名（现有：`marches` / `monsters` / `resources` / `buildings`），与协议列表字段同名
- [ ] `VISIBLE_DEFAULTS` 补缺省
- [ ] 跨片需要清空的字符串字段进 `GHOST_CLEAR_DEFAULTS`
- [ ] `should_project`：无主公共物才投影；有主要贴边可见则显式放行

`visible_bucket` 返回 nil → 合批丢弃。Observer 不要加 bucket。

### 2. `proto.lua`

- [ ] 新 `:type("map_entity_xxx", { ... })`
- [ ] `map_visible_sync_notify` 增加列表字段
- [ ] `map_visible_delta_notify` 增加 `enter_*` 和 `update_*`

协议列表字段必须和 `VISIBLE_BUCKET` 同名（资源桶 / 协议都叫 `resources`）。加新桶时两边一起改。

### 3. `view_sync.lua`

- [ ] `DELTA_SUFFIX` 增加桶后缀（与合批 `enter_*` / `update_*` 一致）
- [ ] `append_to_bucket` 增加分支
- [ ] `new_delta_chunk` / `queue_delta` 初始化新桶（跟现有四个桶同样写法）
- [ ] `aoi_obj_visible`：默认有主且非自己不可见；要给所有人看就显式豁免

### 4. 进场与生命周期

- [ ] `map:attach(obj, TYPE.XXX)` 或 `enter_obj`，不要直接写 `aoi.grids`
- [ ] 销毁走 `leave_obj` / `detach`，保证 ghost 和 `visible_uids` 一起清
- [ ] `uid` 全局唯一，不要复用刚销毁的 id

## 新增属性

先分类再改：

| 种类 | 做法 | 例子 |
|------|------|------|
| 离散、偶尔变 | `VISIBLE_FIELDS` + proto；变时 dirty + `sync_obj_attr_around` | hp、count、level、state |
| 连续轨迹 | 推计划，不要每 tick 推坐标 | 行军 waypoints / speed / wp_index |
| 纯服务端 | 只放模块表，不进 `VISIBLE_FIELDS` | 巡逻 home / tx / wait_until |
| 要落库 | `map_store`；和可见字段分开想 | 主城等级、`patrol_radius` |

清单：

- [ ] `TYPE_FIELDS`（若 ghost / 跨片也要带）
- [ ] `VISIBLE_FIELDS`
- [ ] `VISIBLE_DEFAULTS`
- [ ] 对应 sproto type
- [ ] 写入点 `mark_dirty(obj, "field")` 后调用 attr 同步（或 `broadcast_plan`）

## 移动怎么同步

- **行军**：`DEAD_RECKONING=true`。tick 只 `move_obj`；出发 / 重寻路 / 交战 / 结束 / 开始采集 / 回城才 `broadcast_plan`。交战和采集脏 `state/x/y` 当冻结点。
- **战斗**：到点下发 `battle_duration` 后挂定时器，到期一次写 hp。不要 tick 扣血，也不要战斗过程中 dirty `hp`。取消按已过时间估值再结算。打野走行军 `intent=attack_monster`，不要开副本。
- **采集**：到点下发 `gather_speed/amount/duration` 后挂定时器，到期一次结算。不要 tick 扣余量，也不要采集过程中 dirty `count` / `cargo_count`。取消按已过时间估值再结算。
- **慢速游走（巡逻）**：当前是 `sync_obj_move_around`。新做的连续移动优先学行军计划，不要学每 tick 广播。
- **瞬移 / 传送**：`move_obj` 到新坐标。跨格会自动 leave/enter；**同格则周围人看不到位移**，必须再 `mark_dirty("x"|"y")` + `sync_obj_attr_around`。
- **镜头**：只 `observer.move`。不要写 `st.x/st.y`，玩法距离读主城。

同格短路是正确行为：可见性是格子粒度。不要为了「挪 1 像素也通知」去掉短路。

## 主城、镜头、路由

- 玩法锚点 = `map:get_city(player_id)`，不是 `player_state`
- 新交互距离、行军起点一律读城
- 行军相关客户端请求打到 **主城所在片**（`map_net` 的 `city_shard_id_`）
- 跨片只转 Observer；主城不跟着镜头走
- `player_state` 只放会话：`current_map_id`、`current_scene_id`、`visible_uids`

## 分片与 ghost

- 分片 id 从 1 起，0 表示未设置；不下发客户端（agent 用 RPC 返回值 `with_shard` 和 `remember_march`）
- 实体 `shard_id` = 权威所在片；本片服务是 `map.shard_id`；投影看 `is_ghost`
- 主城生成在本片可走空地（间距 `CITY_SPACING`），`kind=city` 占格写入 `.pathfinding`
- 行军走 `find_map_path`，禁止找不到路时直线穿城
- 权威永远在 `shard_id_of_pos(x,y)` 那一片
- 实体贴边：`Map:sync_ghosts`；邻居 `ghost_upsert` / `ghost_remove`
- 新类型要过片可见：`should_project` + `TYPE_FIELDS` 覆盖投影状态
- 热路径不要 `skynet.call` 全局 `map_service`
- 归属类全图数据：分片结算完 `report_ownership`，读用本地缓存的联盟 buff

## 持久化

落库：身份、配置、需要重载仍在的建筑/怪/资源余量。

不落库：行军路径、交战、`battle_id`、巡逻当前目标、镜头位置、`visible_uids`、资源占点 `occupier_uid`。

改了落库结构要同时改 `map_store` 的读写，并确认重载后 `attach` 仍会 `ensure` 出 AOI 字段。

## 改同步之后怎么验

同一分片 debug console：

```
call .shard.1001.1 "hotspot_start"
call .shard.1001.1 "hotspot_start" { battlers = 0 }
call .shard.1001.1 "hotspot_stop"
```

稳态应大致满足：

- `itemsmax=50`（拆包条目数，不是资源实体）
- `march_tick` 远小于 100ms
- 开交战时 `battle` 钉在配对数；交战过程 **attr 不应再跟 battlers 线性涨**（开战/结算各推一次）
- 新类型若 `attr` 涨了但 `u` 不涨：没进 bucket，或 dirty 字段不在 `VISIBLE_FIELDS`

## 常见故障

| 现象 | 先查 |
|------|------|
| 对象在服务器、客户端没有 | `VISIBLE_BUCKET` / `aoi_obj_visible` / 是否走了 `enter_obj` |
| 有 enter 无 update | 没 `mark_dirty`，或字段不在 `VISIBLE_FIELDS` |
| 同格瞬移对面不刷新 | 缺 attr 推 x,y（同格短路不扫可见性） |
| 行军抖动或包量爆 | 又在 tick 里 `sync_obj_move_around`；应走计划广播 |
| 跨片看不见贴边实体 | `should_project`、HALO、ghost 字段缺 |
| 打了「不能攻击自己的行军」 | 双方 `owner_player_id` 相同且非 0 |
| 合批后客户端丢实体 | 把拆开的 full 当成覆盖；或 enter 不是 upsert |
| 热点 `itemsmax` 不再是 50 | 绕开了 `do_send_delta` / `sync_full` |
