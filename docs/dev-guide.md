# 开发指南

## 跑起来

```bash
./skynet script/init.config        # 单进程开发，客户端直连 8888
```

拆三进程（先 game，再两个 map）：

```bash
./skynet script/init_game.config
./skynet script/init_map1.config
./skynet script/init_map2.config
```

拆进程时客户端改连 **8000**（nginx，见 `script/cluster/nginx-gate.conf`），GM/HTTP 仍是 game 的 8889。

## 端口一览

| 端口 | 用途 |
|------|------|
| 8888 | 单进程 gate（客户端直连） |
| 19001 / 19002 | 双门内网监听（`gate_behind_lb=1`，nginx 8000 反代） |
| 8889 | HTTP / GM |
| 8890 / 8891 / 8892 | debug console：game / map1 / map2（`debug_port` 配置，`service/debug_console.lua` 默认 8890） |
| 2528 / 2529 / 2530 | cluster 口：game / map1 / map2（`script/cluster/clustername.lua`） |

## 调试（debug console）

连 debug 端口后可用 `call` 命令：

```
call .locator "count"            -- 在线人数
call .locator "get", 玩家id       -- 查连接/agent
call .shard.1001.1 "hotspot_start"  -- 大地图压测（见 map/README.md）
call .shard.1001.1 "hotspot_stop"
```

## 热更新

- **业务代码热更**：每个服务通过 `preload.lua` 注入 `_G.CMD.hotfix`；热更模块放 `script/hotfix/`，由 `.hotfix` 服务调度。
- **协议热更**：改 `protocol/proto.lua` 后调 `.protoloader` 的 `reload`，会重新加载 schema 并通知各门 `reload_proto`。

## 加一个服务

1. `script/entry/xxxS.lua`：一行 `bootstrap("service.xxx_service", { name = "xxx" })`。
2. `script/service/xxx_service.lua`：函数暴露成 `M.foo`（会进 `_G.CMD`），`M.init()` 做启动。
3. `script/main.lua` 里 `skynet.newservice("xxxS")` 拉起。
4. 需要跨进程访问时，`service_wrapper` 会自动把服务名登记到 locator，其他节点按注册表找到它；`script/cluster/layout.lua` 的 `NAMED_NODE` 只作启动前的静态兜底，可以不登记。

`service_wrapper` 会自动：注册 `.xxx` 名字、`rpc.export` 到 cluster、**向 locator 登记所在节点**（`rpc.register`）、接入热更新。寻址以 locator 注册表为准，静态表只做兜底（见 [script/cluster/README.md](../script/cluster/README.md) 第 11 节）。

## 加分片 / 加 map 节点

- **已有片换节点**：新进程的 `init_mapN.config` 里写 `local_shards = "3,4"`，不用改 `SHARD_NODE`。新片启动后会自己登记到 locator；**先停旧进程再起新进程**，否则旧租约（120 秒）没到期时新登记会被拒绝（防脑裂）。
- **加新片 / 改网格**：`shard_cols` / `shard_rows` 必须在所有节点配同一组值；改网格等于重新切图，需要数据迁移，不能在线直接加。
- **节点地址变了**（换 IP）：改 `clustername.lua` 后在进程里调 `rpc.reload_cluster()`，不用重启。
- 不要把 locator / login / 门写到 map 节点上。详见 [script/cluster/README.md](../script/cluster/README.md)。

## 服务崩溃与自动恢复

每个 OS 进程最先启动 `.supervisor`，它接管 skynet 的进程级退出通知，按登记的策略重启本进程内的服务：

- `main.lua` 里创建的有名服务、门、`mapS` 由 main 登记；分片和 agent 在自己的 init 里延迟登记（避免重启时反向调用 supervisor 卡住启动）。
- 重启带退避（1s 起，上限 30s；60 秒窗口内超过 10 次就放弃并打错误日志）。门的重启会通过 `start_call` 重新 `open` 监听。
- **只监督同一个 OS 进程**：map1/map2 各自有一个 supervisor，负责本节点的分片；跨进程的服务由所在节点的 supervisor 负责。

agent 池由 supervisor 统一创建和重启（`.agent.<id>` 有名字，登录服重启时据此接管）。agent 退出时：

1. supervisor 立即通知登录服 `agent_down`；
2. 登录服把它从池里剔除、清掉账号映射，并让门踢掉该 agent 上的连接；
3. supervisor 重建 agent 后通知 `agent_up`，登录服接管；
4. 客户端重连时重新登录，按现有分配策略落到健康 agent，玩家数据从 DB 恢复（最多丢最近一次保存，agent 保存间隔 180 秒）。

`eventS` 目前只监督不自动重启：它的订阅表在内存里，重启后订阅方不会自动重订阅，待后续补上再打开自动重启。

## 常见反模式（新人别踩）

- 不要 `skynet.localname(".gate")` / `localname(".locator")` / `localname(".shard.*")` —— 跨服务地址一律 `cluster.rpc` / `shard.addr`。
- 分片下行走 `send_to_conn`，不要拿 agent 记下的 `gate` handle 去 send（split 下会打到错误节点）。
- 热路径（移动 / 视野 / 战斗结算）只在分片内完成，不要路由进全局 map 服务。
