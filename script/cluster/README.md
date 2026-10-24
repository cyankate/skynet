# 拆节点与 Skynet cluster

地图玩法见 [map/README.md](../map/README.md)。本文只讲：**一区如何从单进程变成 `1 game + N map`，以及 Skynet cluster 在这套代码里怎么用。**

小游戏继续单进程：`init.config` 的 `cluster_mode=loopback`（或改成 `standalone`），`gate_count=1`，不要起 map 进程、不要 nginx。

---

## 1. 目标形态

```
客户端 ──TCP──► nginx :8000 ──► gate.1 / gate.2   （game 进程里）
                                      │
                                      ▼
                    game：login / locator / agent / mapS / DB / http:8889
                                      │  cluster TCP
                         ┌────────────┼────────────┐
                         ▼            ▼            ▼
                       map1         map2         mapK
                     shard 1,2    shard 3,4     …
```

- **game 一份**：目录、玩家逻辑、门、寻路、数据库。
- **map × N**：只跑分片 tick / AOI / 行军。贴边两片放同一节点，少打 ghost TCP。
- 业务不要写 `skynet.localname(".gate")`。跨服务地址一律 `cluster.rpc`。

当前 split 配置是 2 个 map、4 片：`SHARD_NODE` 1、2 → `map1`，3、4 → `map2`。

---

## 2. Skynet cluster 本身在做什么

Skynet 默认是 **一个 OS 进程里很多服务**。`skynet.call(addr, "lua", cmd, …)` 走进程内邮箱，地址是本地 handle。

跨进程要用官方 `skynet.cluster`（`lualib/skynet/cluster.lua` + `service/clusterd.lua`）：

| API | 作用 |
|-----|------|
| 配置文件 | `skynet.getenv("cluster")` 指向节点表。每行 `节点名 = "ip:port"` |
| `cluster.open(节点名)` | 本进程按节点表里自己的 `ip:port` 听 **cluster 端口**（不是客户端门） |
| `cluster.register(name, addr)` | 把本进程一个服务登记成 **无点号的名字**，对端用 `@name` 访问 |
| `cluster.proxy(node, name)` | 在本进程生成一个 **代理服务**。之后 `skynet.call(proxy, …)` 会经 TCP 打到 `node` 上那个服务 |
| `cluster.call(node, addr, …)` | 不经 proxy，直接指定对端地址（数字 handle 或 `@name`） |

要点：

1. **harbor 必须是 0**（配置里已写）。老式多节点用 harbor，和 cluster 不要混。
2. **proxy 返回的是本进程里的一个服务地址**。业务侧仍然 `skynet.call/send`，看不出对端在不在本机。
3. 对端名字带 `@`：`proxy("game", "@locator")` 表示「game 上 `cluster.register("locator")` 的那个服务」。我们本地 `skynet.name(".locator")` 和 cluster 名 `locator` 是两套登记。
4. `cluster.open("game")` 里的 `"game"` 必须和节点表、`node_name` 一致。`clusterd` 用这个去表里查自己听哪个端口。
5. **对端进程还没 listen 时**，`cluster.proxy` 会在代理 init 里连 TCP，失败会 assert。所以这套代码 **先探端口再 proxy**，见下文。

官方用法对照：

```lua
-- 进程 A（game）
cluster.open("game")
cluster.register("locator", skynet.self())   -- 对端看到 @locator

-- 进程 B（map1）
cluster.open("map1")
local locator = cluster.proxy("game", "@locator")
skynet.call(locator, "lua", "get_agent", player_id)
```

项目里不要直接调上面这套，走 `cluster.rpc`，避免每处自己拼 `@`、自己处理「对端没起来」。

---

## 3. 三个模式

`cluster_mode` 在各 `init*.config`：

| 模式 | 进程数 | `rpc.named` 怎么拿地址 | 用途 |
|------|--------|------------------------|------|
| `standalone` | 1 | 只 `skynet.localname`，不 `cluster.open` | 最小路径；现配置没用，可当小游戏默认 |
| `loopback` | 1 | 本机有服务则 `cluster.proxy` 打回自己 | **当前 `init.config` 默认**。验证 pack / 时序和 split 一样，但不拆进程 |
| `split` | game + map1 + map2 | 本节点 `localname`，跨节点 `proxy` | 大地图多进程 |

`layout.use_cluster()` = loopback 或 split，才会 `cluster.open` 和 `rpc.export`。

开发：

```bash
./skynet script/init.config          # 单进程，客户端直连 8888
```

验证拆节点（先 game，再 map；对端未起时业务 init 不能死）：

```bash
./skynet script/init_game.config
./skynet script/init_map1.config
./skynet script/init_map2.config
```

客户端改连 **8000**（nginx）。http / GM 仍是 game 的 **8889**。

debug：game `8890`；map1 `8891`（片 1、2）；map2 `8892`（片 3、4）。

---

## 4. layout：谁在哪

文件：`script/cluster/layout.lua`。只回答放置问题，不拿地址。

环境变量：

| getenv | 含义 |
|--------|------|
| `node_name` | 本进程在节点表里的名字：`standalone` / `game` / `map1` / `map2` |
| `cluster_mode` | 上一节三个值 |
| `cluster` | 节点表路径，默认 `script/cluster/clustername.lua` |
| `node_role` | 可省略；不配则从 `node_name` 推：`map1/map2` → `map`，`game` → `game`，否则 `all` |
| `gate_count` / `gate_port` / `gate_behind_lb` / `gate_internal_port` | 门的数量和监听 |

节点表 `clustername.lua`（**cluster 端口，不是客户端端口**）：

```lua
__nowaiting = true
standalone = "127.0.0.1:2528"
game       = "127.0.0.1:2528"
map1       = "127.0.0.1:2529"
map2       = "127.0.0.1:2530"
```

`__nowaiting = true`：对端暂时连不上时 clusterd 不要一直阻塞等（仍建议我们自己探端口）。`standalone` 和 `game` 可以共用 2528，因为不会同时起。

放置规则：

```lua
layout.shard_node(map_id, shard_id)  -- split 下查 SHARD_NODE，否则 = 本节点
layout.named_node(".locator")        -- split 下查 NAMED_NODE / .gate.* / .map.*，都在 game
layout.gate_home_node()              -- 门目前全在 game
layout.local_shard_ids()             -- 本进程该拉起哪些片
layout.is_local(node)                -- node 是否就是 getenv node_name
```

加 map 节点：改 `SHARD_NODE`、`clustername.lua`、加一份 `init_mapN.config`。不要把 locator / login / 门写到 map 上。

---

## 5. rpc：从名字拿到可 call 的地址

文件：`script/cluster/rpc.lua`。返回值永远是 **本进程可 `skynet.call/send` 的地址**（本地 handle 或 cluster proxy）。

```lua
rpc.named(".locator", "game")            -- 指定节点
rpc.named_addr(".locator")               -- 节点由 layout.named_node 决定
rpc.shard_addr(map_id, shard_id)         -- 片名 + layout.shard_node
rpc.export("locator", skynet.self())     -- cluster.register，对端 @locator
```

`named(name, node)` 分支：

1. **目标是本节点，且不是 loopback** → `skynet.localname(name)`（split 下打本机片、standalone）。
2. **loopback 且本机还没有这个 localname** → 返回 nil（服务没起完）。
3. **跨节点** → 缓存里有 proxy 就用；没有则 `node_reachable`（对 `ip:port` 试 `socket.open`），通了再 `clusterd.proxy(node, "@name")`。
4. 探失败或 proxy 失败：记时间，`PROXY_RETRY`（3 秒，单位 `skynet.now()` 0.01s）内不再打，避免 clusterd assert 刷屏。

每个 Skynet 服务是一份独立 Lua VM，`proxies` 缓存在 **调用方服务**里。main 里 prefetch 填的表，shard 服务看不到，所以分片自己第一次 `named` 仍会建 proxy。这是预期。

`rpc.export`：`service_wrapper` 在 `skynet.name("." .. name)` 之后，若 `use_cluster()` 就登记到 clusterd。gate 在 `gateS.lua` 里自己 export（gateserver embed，不能走同一套 start）。

名字对照：

| 本地 `skynet.name` | cluster 登记 | 对端 proxy |
|--------------------|--------------|------------|
| `.locator` | `locator` | `@locator` |
| `.gate.1` | `gate.1` | `@gate.1` |
| `.shard.1001.1` | `shard.1001.1` | `@shard.1001.1` |

---

## 6. 启动顺序

`script/main.lua`：

1. `hotfixS`
2. `layout.use_cluster()` 则 `cluster.open(self_node())` —— **先听 cluster 口，再起业务**，否则对端来连会 Connection refused。
3. **role == map**：只拉 `layout.local_shard_ids()` 对应的 `shardS`，然后 `prefetch_remote_shards`，main **不能 `skynet.exit()`**（否则 fork 出去的预取协程没了）。
4. **game / all**：locator → login → … → 各 `gateS` → pathfinding → mapS → prefetch；再 `open` 各门监听。
5. split 下 game 的 main 也不 exit。

map 进程 **不** 起 login / db / gate。分片要 DB / locator / 门，全部 `rpc.named_addr` 打到 game。

`prefetch_remote_shards`（仅 split）：后台每 2 秒探一次对面 map 的 cluster 口，建齐所有远程片的 proxy 后，对本机片发 `resync_border_ghosts`。这样可以 **game 先起、map 后起**，或 map1 比 map2 早起，init 阶段不会因为 proxy 连失败把服务拉死。

---

## 7. 门、locator、两条下行

多门只在 **game 进程内** 加服务，不拆机器。

- `gate_count=1`：听 `gate_port`（默认 8888），客户端直连。
- `gate_count=2` 且 `gate_behind_lb=1`：听 `127.0.0.1:19001/19002`，公网 **nginx stream 8000** 反代（`nginx-gate.conf` 用 `include` 进系统 nginx，不要 `nginx -c` 当主配置）。http 仍占 8889，所以双门不能再占 8888/8889。

在线目录 `.locator`（game）：

```
player_id → { name = ".gate.1", node = "game", agent = <game 本地 handle> }
```

- **gate** 随连接变：`register_player` bind，断开 unbind，顶号 kick。
- **agent** 跟逻辑进程：闪断宽限期内仍在；卸号 `remove`。
- 换门时 locator 向 **所有片** `forget_player_gate`，清分片 VM 里的门缓存。

下行：

| API | 路径 | 谁用 |
|-----|------|------|
| `send_to_player` | locator 查 agent → `push_client` → 门句柄 | 背包、好友、登录回包 |
| `send_to_conn` | 分片 `rpc.player_gate`（本 VM 缓存，miss 才 `get_gates`）→ 门 `send_to_player` | AOI、行军同步 |

agent 记下的 `account.gate` 是 **game 本地句柄**，不能出 game。分片不能 `send_to_player` / `call_agent` 拿这个 handle 去 send（split 下会打到 map 上错误的本地服务）。热路径只用 `send_to_conn`。

C2S 仍是门上 `skynet.redirect` 到本进程 login/agent，**跨节点无效**。现在门和 agent 同在 game，所以没问题。以后真把 gate 拆出独立进程，要改成 `cluster.send`，门地址一律 `rpc.named(name, node)`。

---

## 8. 业务侧怎么写

```lua
local rpc = require "cluster.rpc"
local layout = require "cluster.layout"
local locator = require "cluster.locator"
local shard = require "map.shard"

-- 固定名字的服务（login / locator / pathfinding …）
local locatorS = rpc.named_addr(".locator")
skynet.call(locatorS, "lua", "get_agent", player_id)
-- 或 locator.get_agent(player_id)

-- 分片
local addr = shard.addr(map_id, shard_id)  -- 内部 rpc.shard_addr
skynet.send(addr, "lua", "leave_map", player_id)

-- 不要
skynet.localname(".gate")
skynet.localname(".locator")   -- http GM 已改走 cluster.locator
```

`cluster.locator` 是 locator 服务的客户端封装，内部还是 `rpc.named_addr(".locator")`。

---

## 9. 和「直接用 cluster.*」的差异（为什么包一层）

| 直接 cluster | 这套 rpc |
|--------------|----------|
| 对端没起 proxy init 崩 | 先探 TCP，失败返回 nil |
| 调用方自己记得 `@` 和节点名 | `layout` 查表 |
| loopback 无法用同一套调用 | `named` 按 mode 切换 localname / proxy |
| 每处 `cluster.call("game", "@locator", …)` | 拿到 addr 后与单进程相同的 `skynet.call` |

loopback 的意义：单进程也走 pack → clusterd → 自己，把「跨进程时序 / 序列化」的 bug 在开发机暴露出来，而不用天天起三个进程。

---

## 10. 小游戏 / 单进程

只改配置，不要 fork 仓库：

- `init.config`：`cluster_mode=loopback`（或 `standalone`）、`gate_count=1`、`node_name=standalone`
- 不启动 `init_map*.config`，不挂 nginx
- 客户端 8888；需要的话把 `cluster_mode` 改成 `standalone`，连 clusterd 都不开，`rpc.named` 退化成 `localname`

加片、加门、加 map 进程都是改 `layout` + 配置，业务调用保持 `rpc.named*`。
