# CLAUDE.md

基于 [skynet](https://github.com/cloudwu/skynet) 的 Lua 手游服务端：SLG 大地图（分片 / 行军 / 战斗）+ 养成 + 匹配副本。

## 构建 / 运行

- 构建：`make`（产出 `./skynet` 与 C 扩展 `.so`）
- 清理：`make clean`（连依赖一起清 `make cleanall`）
- 单进程开发跑：`./skynet script/init.config`
- 拆三进程：`./skynet script/init_game.config` + `script/init_map1.config` + `script/init_map2.config`
- 纯 Lua 业务改动可热更；加服务 / 改协议 / 热更细节见 docs/dev-guide.md

## 目录职责

- `skynet-src/` `service-src/` —— C 核心与 C 服务，一般不动
- `lualib-src/` —— C 扩展库（sproto / bson / cjson …）
- `script/` —— Lua 业务（service / entry / cluster / map …）
- `protocol/` —— sproto 协议
- `docs/` —— 项目文档，入口 docs/README.md

## 高频规范（别踩）

- 跨服务地址一律 `cluster.rpc` / `shard.addr`，不要 `skynet.localname(".gate" / ".locator" / ".shard.*")`
- 分片下行走 `send_to_conn`，不要拿 agent 记下的 gate handle 去 send
- 热路径（移动 / 视野 / 战斗结算）只在分片内，不要路由进全局 map 服务
- 加服务：entry → service → main.lua（服务名自动登记到 locator，layout 静态表只做兜底；见 docs/dev-guide.md「加一个服务」）
- 服务崩溃：本进程由 `.supervisor` 自动重启（退避上限 10 次）；卡死由 30 秒心跳看门狗判断（连续 3 次不响应则通知并尝试 kill）；agent 池由 supervisor + 登录服协同恢复；`eventS` 暂不自动重启
- 关键跨服务调用（绑定 / 上下线 / 结算 / 状态变更）用 `rpc.call_timeout`，不要裸 `skynet.send`；通知类消息才用 `send`

## 文档与检查

- 详细文档看 docs/README.md；改动后可用 `project-docs` skill 同步文档、`change-check` skill 自检。
