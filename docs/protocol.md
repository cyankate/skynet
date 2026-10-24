# 协议体系

客户端 ↔ 服务端通信用 **sproto**（`sprotoloader`）。C2S 是客户端请求，S2C 是下行通知。

## 数据流

```
客户端 ──TCP──► gate（sproto 解包）
                  │  skynet.redirect 到本进程 login / agent
                  ▼
              agent（net.msg_net 按协议名分发）
                  │  调 system/*_mgr 或 map 分片
                  ▼
        protocol_handler 回包（经门 send_to_client / send_to_player）
```

## 关键文件

| 文件 | 作用 |
|------|------|
| `script/protocol/proto.lua` | 协议定义（`c2s`、`s2c` 两套 sproto 文本），协议号 |
| `script/protocol/proto_builder.lua`、`script/utils/proto_builder.lua` | 由定义生成 schema，写进 datacenter |
| `script/protoloader.lua` | `.protoloader` 服务：`sprotoloader.save(c2s,1)` / `save(s2c,2)`，同步 schema，通知各门 reload |
| `script/net/msg_net.lua` | 汇总各域 C2S 处理器成一张 `{协议名 → 函数}` 表 |
| `script/net/*_net.lua` | 按域拆分的 C2S 处理：`player_net` / `chat_net` / `friend_net` / `guild_net` / `mail_net` / `instance_net` / `play_net` / `task_net` / `map_net` |
| `script/protocol_handler.lua` | 下行统一出口 |

`msg_net.lua` 是聚合点：它 `require` 上面每个 `*_net` 模块，把各自返回的 handler 表合并成一张。agent 在 `agent_service.lua` 里 `require "net.msg_net"` 拿这张表，收到门转来的包后按协议名分发。

## C2S 处理器的样子

以 `map_net.lua` 为例：函数签名是 `(player, msg)`——`player` 是玩家对象（`user_mgr` 取），处理完经 `protocol_handler` 回包。一个 C2S 处理器 = 取玩家 → 校验 → 调系统/地图模块 → 回包。

## 下行路径（`protocol_handler`）

| API | 路径 | 谁用 |
|-----|------|------|
| `send_to_client(fd, name, data, gate)` | 直接按连接 fd 发 | 登录回包等有 fd 的场景 |
| `send_to_player(player_id, name, data)` | 查 agent → `push_client` → 门 | 背包、好友、邮件等业务下行 |
| `send_to_players(player_ids, …)` | 按 agent 分组群发 | 群发 |
| `send_to_conn(player_id, …)` | 查门直推连接 | 分片热路径（AOI、行军） |
| `call_agent` / `send_to_agent` | 直接调玩家 agent | 需要玩家上下文时 |

分片热路径只走 `send_to_conn`（`rpc.player_gate` 查门直推），不经过 agent，避免跨进程拿 game 本地 handle 出错。

## 大地图视野协议

大地图视野同步只走两条协议（见 [script/map/README.md](../script/map/README.md)）：

- `map_visible_sync_notify`（805）：进图 / 重连快照
- `map_visible_delta_notify`（806）：enter / leave / update 四类桶

业务禁止绕过 `view_sync` 直接 `send_to_conn` 这两条。

## 改协议怎么生效

改 `protocol/proto.lua` 后，调 `.protoloader` 的 `reload`：重新 `sprotoloader.save`、同步 schema、通知各门 `reload_proto`。见 [dev-guide.md](dev-guide.md)。
