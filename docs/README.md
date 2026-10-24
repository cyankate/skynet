# 项目文档

一个基于 [skynet](https://github.com/cloudwu/skynet) 的 Lua 手游服务端：SLG 大地图（分片 / 行军 / 战斗）+ 养成系统 + 匹配副本。这里是新开发者上手的第一入口。

## 我该先读什么

- **10 分钟了解全貌** → [architecture.md](architecture.md)
- **看有哪些服务、各自干嘛** → [services.md](services.md)
- **把项目跑起来 / 调试 / 热更新** → [dev-guide.md](dev-guide.md)
- **客户端协议怎么走** → [protocol.md](protocol.md)
- **数据存哪了** → [storage.md](storage.md)
- **玩法系统（养成 / 匹配 / 副本）** → [gameplay.md](gameplay.md)

## 深入某个模块

- 大地图（分片 / AOI / 行军 / 战斗）：[script/map/README.md](../script/map/README.md) + [MAINTAIN.md](../script/map/MAINTAIN.md)
- 进程拆分与 cluster：[script/cluster/README.md](../script/cluster/README.md)
- 安全 / 支付 / 加密：[script/security/README.md](../script/security/README.md)

## 文档索引

| 文档 | 内容 |
|------|------|
| [architecture.md](architecture.md) | 整体架构、进程/服务拓扑、分层与关键模式 |
| [services.md](services.md) | 服务目录（每个服务的职责、入口、核心模块） |
| [protocol.md](protocol.md) | 协议体系（sproto、C2S 入口、下行路径） |
| [storage.md](storage.md) | 持久化（MySQL / Redis / Mongo 分工、cache） |
| [dev-guide.md](dev-guide.md) | 开发指南（跑起来、端口、调试、热更新、加服务） |
| [gameplay.md](gameplay.md) | 玩法总览（养成 / 匹配 / 副本 / 场景） |

> 本文档目录由 `.claude/skills/project-docs` 维护；改动代码后可让它根据 `git diff` 同步更新。
