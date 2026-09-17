# 大地图框架设计

开发、加类型、改字段请看 [MAINTAIN.md](MAINTAIN.md)。本文只描述「这套框架是什么、为什么这样拆」。

## 定位

一张连续大世界（默认 `map_id=1001`，2048×2048），按矩形切成多个分片服务。坐标始终是全图像素，不在分片内局部化。权威实体只存在于所属分片；贴边邻居以 ghost 镜像进 AOI。

热路径（移动、视野、战斗结算、行军 tick）永远在分片内完成。全局地图服只做注册表和派生状态，崩溃后可以从分片重建。

## 服务拓扑

```
main
  └── mapS          全局地图服（每张图一个）service/map_service.lua
        └── shardS × N   分片服            service/shard_service.lua
              ├── Map + MapAOI
              ├── observer / view_sync
              ├── march_runtime / march_gather / march_battle / monster_ai / interact
              └── map_store
```

启动：`mapS` 拉起全部 `shardS`。分片名 `.shard.<map_id>.<shard_id>`，全局名见 `map.shard`。
全图一份导航：`pathfindingS`（`.pathfinding`），主城占格写在这里，行军 `find_map_path` 都问它。

当前默认 2×2 = 4 片，id 为 1..N; 切分单位是 chunk，再聚合成分片矩形（`shard.pixel_rect`）。

### 全局服（map_service）

- 争夺建筑归属注册表（分片战斗回写后 `report_ownership`）
- 联盟 buff 聚合后回推各片缓存（分片本地读，热路径零跨服）
- 全图统计 / 赛季进度（占位）

反模式：不要把镜头移动、AOI、扣血路由进这个服务。

### 分片服（shard_service）

CMD 只做对外入口，转发到模块。本片持有：

- 本矩形内的权威实体
- 贴边 ghost
- 本片观察者（镜头）及其 `player_state`
- 行军 / 野战 / 巡逻 tick

## 坐标与角色

三套坐标不要再混：

| 概念 | 是什么 | 存在哪 |
|------|--------|--------|
| 镜头 / Observer | AOI 订阅中心，玩家拖地图 | `Observer` 实体，`uid = player_id` |
| 主城 | 玩法锚点（出发、交互距离） | `BUILDING`，`uid = city_<player_id>` |
| `player_state` | 视野会话 | `visible_uids`、`current_map_id`、当前片；**不存玩法坐标** |

`observer.move` 只挪镜头，跨片转的是观察者，不是主城。行军从主城所在片出发（agent 缓存 `city_shard_id_`）。分片 id 是服务端路由，不下发客户端。

## 对象模型

统一叫 obj，契约在 `aoi_object.lua`。

- **AoiObj**：空间底座（uid、type、x/y、shard）
- **Observer**：带 `view_range` 的镜头，不同步给他人
- **WorldObj**：可投影、可交互（行军 / 怪 / 资源 / 建筑）
- **ghost**：同型投影（`is_ghost=true`），不是单独 type

字段分四层：

1. `BASE_FIELDS` — 所有类型
2. `WORLD_FIELDS` — 世界对象公共（alive、owner）
3. `TYPE_FIELDS` — AOI / ghost 边界需要的扩展
4. `VISIBLE_FIELDS` — 打给客户端的可见字段

未进 `VISIBLE_FIELDS` 的状态（巡逻目标点、等待时间等）是模块运行时，不进协议、默认不落库。

地图上的采集物叫 **resource**（`TYPE.RESOURCE`、协议桶 `resources`）。`item` 留给背包；拾取协议仍是 `map_pick_item`，实体上的 `item_id` 是进包的道具模板，不是地图类型名。

可见性默认：有主且不是自己则不可见。行军、建筑已豁免为全图可见。无主（owner 为 nil/0）之间可以交战；同一非 0 玩家不能打自己的行军。

## AOI

`map_aoi.lua`：格子索引，默认 `grid_size=50`。

- 实体进/出/移动：`Map:enter_obj` / `leave_obj` / `move_obj`
- 观察者周围实体、实体周围观察者分两套索引
- **可见性按格子窗口判定**（`in_observer_range` 比格子号）。同格内移动不可能改变任何观察者的 enter/leave，`sync_visible_move` 直接短路

贴边投影：`HALO_RANGE=120`（≥ 视野）。`should_project` 为真才向邻居 `ghost_upsert`。有主对象默认不投影；需要贴边可见的类型要显式放行。

## 视野同步

观察者看到的世界只走两条协议：

- `map_visible_sync_notify`（805）：进图 / 重连快照
- `map_visible_delta_notify`（806）：enter / leave / update 四类桶

业务禁止直接 `send_to_player` 这两条。入口是 `view_sync`：

- 进/离/跨格 → 实体侧扫周围观察者，补 enter 或 leave
- 属性变化 → `mark_dirty` + `sync_obj_attr_around`（100ms 合批，只打包脏字段）
- 连续坐标流 → `sync_obj_move_around`（同样 100ms 合批；行军在心跳推算下不再走这条）

同一观察者 100ms 窗口内的 enter/leave/update 合并成一包，再按 **50 条**拆帧。规则：

- enter + leave 窗口内对消
- leave 优先于 update
- enter + update → 合并进 enter 全量包
- 超 50 条：leave → update → enter 顺序切多帧
- `sync_full`：**只有第一帧走 full**，溢出改立刻下发的 delta enter（避免客户端覆盖语义把前一帧抹掉）

客户端约定：enter = upsert；update 只覆盖非 nil 字段。

属主私有通道（如 `map_march_sync_notify`）是玩法通知，不是 AOI，不能替代周围观察者同步。

## 主城、占格、寻路

首次进图：本片没有主城则在**可走空地**建一座 `BUILDING`（`uid=city_<player_id>`，`kind=city`），不再叠在 `def.start` 同一点。选点避开已有占格，间距 `CITY_SPACING`（默认 96）。

建筑进 AOI 后向 `.pathfinding` 登记圆形障碍（半径 `CITY_BLOCK_RADIUS=16`，约 2 个导航格）。行军不占格。回城判定 `CITY_ARRIVE_RANGE` 大于占格半径，停在城边缘即可交货。

格子图 cell=8，A* 在 `pathfindingS`。找不到路时行军失败或停住，**不会直线穿城**。寻路服不可用时才退回直线（开发兜底）。

## 行军与心跳推算
 
行军是独立实体，坐标权威跟位置走，交战权威跟攻击者走。

`march.DEAD_RECKONING = true`：

- tick 只 `move_obj` 维护格子，**不下发每 tick 坐标流**
- 出发 / 重寻路 / 交战 / 战斗结束才广播计划：`waypoints + wp_index + speed + x,y(rebase)`
- 客户端从权威坐标按剩余路点外推
- 交战时脏 `state/battle_id/x,y` 作为冻结点，结束再 rebase

野战在攻击者所在片结算，防守方可能跨片（`march_set_defender`）。交战权威是**到点一次结算**，不是 tick 扣血：

- 追击进 `ENGAGE_RANGE`（或 `intent=attack_monster` 到怪）后冻结双方，下发 `battle_id` / `battle_duration`
- 用开战快照 hp 和 `DAMAGE/TICK_SEC` 算出持续时间，挂一个定时器；到期按计划写剩余 hp，死人则 despawn
- 中途取消按已过时间估值。属主私有 `map_march_battle_notify` 只发 `engage` / `end`，不发过程 tick
- AOI 观众只看到停下来打，用 duration 播动画；hp 只在结算时 dirty 一次

打野是行军任务，不再从主城距离开副本：

- `map_interact_monster` 从主城发 `intent=attack_monster` 的行军（无城边距离限制）
- 到点开战、结算；打赢回城，打输行军消失；怪 `battle_id` 非空时不巡逻、不可再打
- 已有行军也可以 `map_march_attack` 指定怪 uid

采集是行军任务，不是瞬间拾取：

- `map_march_gather`：从主城出发，`intent=gather`，`target_uid` 为资源点
- 到点独占 `occupier_uid`，`state=gathering` 冻结坐标，下发采集计划：`gather_speed` / `gather_amount` / `gather_duration`
- 余量和货物**不实时同步**。客户端按开始快照的 `count` + 速度×时间估值；服务端只挂一个采完定时器，到期一次扣余量、写入 `cargo_count` 再回城
- 中途取消按已过时间估值结算后回城。`map_pick_item` 只留给非 `gatherable` 的掉落物

## 持久化

`map_store` 落库的是身份和配置（怪、资源、主城等），不是所有运行时。

典型不落库：行军路径、交战、巡逻当前目标点、资源 `occupier_uid`。落库：`kind`、`patrol_radius`、建筑等级、资源余量 `count`。重载后巡逻以落库坐标为圆心重新跑；占点行军不恢复，余量保留。

## 压测锚点

`hotspot_test` 在单片热点里打满：静止观察者 + 镜头 churn + 行军游走 + 配对野战 + 巡逻怪。用来回归「合批 / 拆包 / 心跳推算 / 同格短路」是否还成立，不是玩法测试。

入口（debug console）：

```
call .shard.1001.1 "hotspot_start"
call .shard.1001.1 "hotspot_stop"
```
