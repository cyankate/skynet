# 玩法总览

大地图（`script/map/`）之外，还有一整套玩家养成与副本玩法。这里给高层图景，深入以代码为准。

## 养成系统（`script/system/` + `player_obj`）

玩家的属性和成长由一堆 `*_mgr` 模块组成，`script/player_obj.lua` 的 `Player` 类把它们聚合起来：

- `item_mgr` 物品、`talent_mgr` 天赋、`weapon_mgr` 武器、`head_mgr` 头像/主将
- `recovery_mgr` 恢复、`barrier_mgr` 屏障、`condition_mgr` 条件、`effect_mgr` 效果
- `task` 任务、`rank` 排行榜、`global` 全局数据

`script/effect/`（`attr_calc` + `effect_core`）做属性计算；`script/ctn/` 是「容器」抽象（背包 `ctn_bag`、日常 `ctn_day`、周常 `ctn_week`、任务 `ctn_task`、条件 `ctn_condition`），挂在玩家会话（agent）上。

配置在 `script/setting/*_DATA.lua`（`ITEM_DATA`、`TALENT_DATA`…），枚举/常量在 `script/define/*_def.lua`（`event_def`、`condition_def`、`item_def`…）。

## 匹配 → 副本 → 场景

```
match（匹配队列）──► instance（副本实例）──► scene（实例内场景空间）
```

- **match**（`match/match_mgr.lua`）：通用匹配流程层——匹配队列（matching）→ 待确认（pending_confirm）→ 确认/拒绝/超时；规则在 `match/play_rules.lua`，模式适配在 `match/adapters/`。
- **instance**（`instance/instance_mgr.lua`）：副本实例管理——实例生命周期、类型（`instance/types/`、`instance/modes/`，含 `rogue`）、结束判定（`define/inst_def.lua`）。
- **scene**（`scene/scene_mgr.lua`）：实例内的场景空间，0.1s tick。场景里有 `entity`、`grid_aoi`（格子 AOI）、`monster_entity`、`ai`、场景内寻路。

## 和大地图（map）的区别

项目里有**两套空间框架**，不要混：

| | 大地图 `script/map/` | 副本场景 `script/scene/` |
|---|---|---|
| 规模 | 一张 2048×2048 连续世界，按 chunk 切成 4 片（多进程） | 副本实例内的场景（单服务内） |
| AOI | `map_aoi` 格子 + 贴边 ghost 投影 | `grid_aoi` 格子 |
| 玩法 | 行军 / 野战 / 采集 / 怪物巡逻 | 副本战斗 / 怪物 AI / rogue |
| 权威 | 分片 `shardS` | 场景 `sceneS` |

客户端进副本和进大地图是两条路径，分别由 `instance_net.lua` / `map_net.lua` 处理。

## 其它玩法服务

聊天（频道 + 限流）、好友、联盟、邮件、排行榜、赛季、支付，对应各自服务，见 [services.md](services.md)。
