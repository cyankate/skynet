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
- **卡死看门狗**：每 30 秒 ping 一次被监督服务（0.5 秒超时），连续 3 次无响应先通知 `on_down`（agent 会走登录服剔除/踢人），再尝试 `skynet.kill`；真正的重启仍由退出通知统一处理，避免重复拉起。基础设施（`dbS` / `redisS` / `mongoS`）和 `eventS` 只告警不自动 kill，避免长查询误杀或订阅表丢失后无人重订阅。
- **只监督同一个 OS 进程**：map1/map2 各自有一个 supervisor，负责本节点的分片；跨进程的服务由所在节点的 supervisor 负责。
- 服务需要响应 `ping` 才能被看门狗正确判断：`service_wrapper` 已内置，`gateS` / `redisS` 已单独处理；新增不走 wrapper 的服务要自己实现。

agent 池由 supervisor 统一创建和重启（`.agent.<id>` 有名字，登录服重启时据此接管）。agent 退出时：

1. supervisor 立即通知登录服 `agent_down`；
2. 登录服把它从池里剔除、清掉账号映射，并让门踢掉该 agent 上的连接；
3. supervisor 重建 agent 后通知 `agent_up`，登录服接管；
4. 客户端重连时重新登录，按现有分配策略落到健康 agent，玩家数据从 DB 恢复（最多丢最近一次保存，agent 保存间隔 180 秒）。

`eventS` 目前只监督不自动重启：它的订阅表在内存里，重启后订阅方不会自动重订阅，待后续补上再打开自动重启。

## 跨服务调用与关键消息

- 关键路径（账号绑定、上下线、结算、物品/支付）用 `rpc.call_timeout(addr, timeout, method, ...)`：`timeout` 单位 0.01 秒，返回 `completed, ret1, ret2`；超时返回 `false, nil, "timeout"`，不会把调用方一起拖死。
- 超时后远端仍可能继续处理，**重试必须幂等**；agent 的 `start` 已用 `req_id` + `script/utils/idempotent.lua` 去重，支付/物品类后续要接同一套或落库 outbox。
- 通知类（视野、AOI、ghost、日志、在线状态）继续用 `skynet.send`，丢了靠下一次同步或补偿。
- 不要把 `send` 全量改成 `call`：会造成阻塞和级联故障。

## 存档与一致性

- **玩家级保存锁**：`Player:exclusive(fn)` 用 `skynet.queue` 串行化同一玩家的定时保存和关键提交；`Player:save_to_db()` 异步但串行，`Player:save_to_db_sync()` 用于卸载/关服等需要确认落库的场景。
- **容器同步保存**：`CtnBase:save_now()`，由 Player 的锁串行调用；定时保存也走同一条路径，避免旧快照覆盖新提交。
- **关键提交**：后续业务应复用 `Player:exclusive`，把“受影响的容器 + op_log”放在 `dbS` 的同一个事务里；只提交这次操作必须一起变的字段，其他模块继续等定时保存。
- 定时保存走 `batch_insert` / `batch_update`，同步返回结果；关键提交走 `Player:commit_critical`。

### 关键提交（op_log）

- `op_log` 表（迁移 `[#5]`）：`op_id` 唯一主键、`status`、`result`、时间。
- `dbS.commit_op(op_id, ops, result)`：`ops` 是 `{op="insert|update|upsert|delete", tbl=..., data/rows/cond}` 的列表；内部在同一事务里写 `op_log` + 业务行；重复 `op_id` 返回上次结果。
- `dbS.transaction(ops)`：只做多表事务，不写 `op_log`。
- `dbS.op_get(op_id)`：查询操作是否已完成及结果。
- `Player:commit_critical(op_id, {"bag"}, extra_ops, result)`：复用玩家保存锁，把容器快照 + `op_log` 同事务提交。
- `Player:grant_items_critical(op_id, items, reason)`：单玩家发奖的幂等入口；提交失败时保留 pending，定时保存会跳过该容器，按同一 `op_id` 重试。
- 支付奖励：`paymentS.handle_notify` 更新订单后尝试发奖；玩家离线时登录 agent 触发 `paymentS.claim_player_rewards` 补发；agent 侧按 `pay:<order_id>` 幂等。
- outbox / 死信重放仍属于后续阶段。

## 常见反模式（新人别踩）

- 不要 `skynet.localname(".gate")` / `localname(".locator")` / `localname(".shard.*")` —— 跨服务地址一律 `cluster.rpc` / `shard.addr`。
- 分片下行走 `send_to_conn`，不要拿 agent 记下的 `gate` handle 去 send（split 下会打到错误节点）。
- 热路径（移动 / 视野 / 战斗结算）只在分片内完成，不要路由进全局 map 服务。
