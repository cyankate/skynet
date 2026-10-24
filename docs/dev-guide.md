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
4. 需要跨进程访问时，在 `script/cluster/layout.lua` 的 `NAMED_NODE`（或 `.xxx` 规则）登记它落在哪个节点。

`service_wrapper` 会自动：注册 `.xxx` 名字、`rpc.export` 到 cluster、接入热更新。

## 加分片 / 加 map 节点

改 `script/cluster/layout.lua` 的 `SHARD_NODE` + `script/cluster/clustername.lua` + 加一份 `script/init_mapN.config`。不要把 locator / login / 门写到 map 节点上。详见 [script/cluster/README.md](../script/cluster/README.md)。

## 常见反模式（新人别踩）

- 不要 `skynet.localname(".gate")` / `localname(".locator")` / `localname(".shard.*")` —— 跨服务地址一律 `cluster.rpc` / `shard.addr`。
- 分片下行走 `send_to_conn`，不要拿 agent 记下的 `gate` handle 去 send（split 下会打到错误节点）。
- 热路径（移动 / 视野 / 战斗结算）只在分片内完成，不要路由进全局 map 服务。
