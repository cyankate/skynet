# 整体架构

一个基于 skynet（Lua actor 模型）的手游服务端：SLG 大地图 + 养成 + 匹配副本。核心是「一张连续大世界按矩形切成多个分片，贴边以 ghost 镜像进 AOI」，同时有一整套玩家养成与副本玩法。

## 技术栈

- **引擎**：skynet（C 核心 + Lua 业务）。`3rd` 依赖 jemalloc / lpeg / lua-cjson / lua-md5 / luasocket / recastnavigation。
- **协议**：sproto（`sprotoloader`），协议号与 schema 见 [protocol.md](protocol.md)。
- **存储**：MySQL（`db`）、Redis（`redis`）、MongoDB（`mongo`），见 [storage.md](storage.md)。
- **进程拆分**：官方 `skynet.cluster`，封装在 `script/cluster/`，见 [script/cluster/README.md](../script/cluster/README.md)。

## 进程 / 服务拓扑

三种运行模式（`cluster_mode`）：

- `standalone`：单进程，`rpc.named` 退化成 `localname`，不开 cluster。
- `loopback`：单进程，但走 cluster 环回（当前 `init.config` 默认），开发期暴露跨进程时序/序列化问题。
- `split`：`game + map1 + map2` 三进程，地图分片分布到多个进程。

```
客户端 ──TCP──► nginx :8000 ──► gate.1 / gate.2   （game 进程里）
                                      │
                                      ▼
                    game：login / locator / agent / mapS / DB / http:8889
                                      │  cluster TCP
                         ┌────────────┼────────────┐
                         ▼            ▼            ▼
                       map1         map2         …
                     shard 1,2    shard 3,4
```

单进程开发：`init.config` 直连 **8888**，`gate_count=1`，不起 map 进程、不挂 nginx。

`main.lua` 的启动顺序（game / all）：

1. `hotfixS` → `cluster.open`（先听 cluster 口，再起业务）
2. `protoloader` → `dbS` / `redisS` / `mongoS` → `locatorS` → `loginS`
3. 各玩法服务：`rankS` / `guildS` / `globalS` / `chatS` / `httpS` / `mailS` / `friendS` / `paymentS`
4. 若干 `gateS`（监听）→ `matchS` / `instanceS` / `pathfindingS` → `mapS`
5. `prefetch_remote_shards`（split 下后台连远程分片）

map 进程只拉 `shardS`；login / db / gate 都在 game，分片要用它们都走 `rpc.named_addr` 打到 game。

## 分层

```
script/
  entry/      服务启动入口（薄，一行 bootstrap 或 gateserver）
  service/    服务逻辑（函数暴露成 _G.CMD 供 dispatch）
  net/        C2S 协议入口（每域一份，挂在玩家/agent 上）
  system/     玩法系统（养成、好友、联盟、任务、物品…）
  map/        大地图框架（分片 / AOI / 行军 / 战斗）
  scene/      副本内场景（entity / grid_aoi / monster / ai）
  instance/   副本实例管理
  match/      匹配
  cluster/    进程拆分（layout / rpc / locator）
  protocol/   协议定义（sproto）
  sql/ mongo/ cache/   持久化与缓存
  define/ setting/     枚举与配置表
  runtime/    service_ctx（热更新保状态的注册表）
  utils/      工具（service_wrapper / class / 时间 / id 生成…）
```

## 关键模式

- **每个服务一个独立 Lua VM**。`utils/service_wrapper.lua` 统一做：分发 `_G.CMD`、注册 `.name`、`rpc.export`、接入热更新、统计耗时。
- **状态存 `service_ctx`**：`runtime/service_ctx.lua` 的 `service_ctx.get(key)` 把状态放进 `_G` registry，热更新时内存状态不丢。
- **跨服务取地址只走 `cluster.rpc`**：`rpc.named_addr(".locator")` / `shard.addr(map_id, shard_id)`。业务**不要** `skynet.localname(".gate")` / `localname(".shard.*")`。
- **两条下行**（`protocol_handler`）：
  - `send_to_player`：查 agent → `push_client` → 门（背包、好友、登录回包等）。
  - `send_to_conn`：分片热路径，查门直推（AOI、行军同步）。
- **热更新**：`preload.lua` 给每个服务注入 `_G.CMD.hotfix` 等命令，`hotfixS` 统一调度；`service_wrapper` 启动后延迟注册到 hotfix。

## 往下看

- 服务清单：[services.md](services.md)
- 协议与下行：[protocol.md](protocol.md)
- 玩法总览：[gameplay.md](gameplay.md)
- 大地图深入：[script/map/README.md](../script/map/README.md)
- 进程拆分深入：[script/cluster/README.md](../script/cluster/README.md)
