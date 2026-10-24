# 文档结构与编写规范

## 分层模型

| 层 | 位置 | 内容 | 维护者 |
|----|------|------|--------|
| 总览层 | `docs/` | 架构、服务目录、协议、存储、开发指南、玩法概述 | 本 skill |
| 模块深度层 | `script/*/README.md`（cluster、map、security 等） | 单个子系统的设计细节 | 各模块作者 + 本 skill |
| 根目录 | `README.md`（skynet 引擎）、`HISTORY.md` | 引擎说明、变更历史 | 引擎上游 |

`docs/` 是给新人的第一入口；模块 README 是给需要深入某块的人的。两层之间用链接引用，**不要复制内容**，避免两处漂移。

## docs/ 目录规范

- `README.md` —— 索引 + 新手上手路线（按角色/目标导航）。**任何新文档都要在这里登记一行。**
- `architecture.md` —— 整体架构（技术栈、进程/服务拓扑、分层、关键模式）。
- `services.md` —— 服务目录（每个服务：职责一句话、入口文件、核心模块）。
- `protocol.md` —— 协议体系（sproto、proto_builder、protoloader、C2S 入口、下行路径）。
- `storage.md` —— 持久化（MySQL/Redis/Mongo 分工、cache、schema）。
- `dev-guide.md` —— 开发指南（跑起来、端口、调试、热更新、加服务/加分片/改协议）。
- `gameplay.md` —— 玩法总览（养成 / 匹配 → 副本 → 场景）。够大时再拆 `gameplay/` 子目录。

## 文档模板

### 总览类（architecture.md）

1. 一句话定位。
2. 一张拓扑图（ASCII 或 mermaid，参考现有文档的画法）。
3. 关键概念 / 模式列表。
4. 指向其它文档的链接。

### 单个服务（services.md 每小节，或 gameplay 单篇）

```
## 服务名（.name）

一句话职责。

- 入口：`script/entry/xxxS.lua` → `script/service/xxx_service.lua`
- 核心模块：`script/system/xxx/...`
- 关键接口 / CMD：...
- 依赖：MySQL / Redis / 其它服务
```

### 流程 / 协议类（protocol.md）

先画「客户端 → 门 → 服务」数据流，再列协议族和文件位置。

## 编写风格

- 中文，术语一致（分片、行军、门、agent、locator、cluster、sproto、ghost、AOI）。
- 每个文档开头 1-2 句「这是什么」，让读者 30 秒内判断要不要继续看。
- 用代码内真实标识符：文件名 `路径/文件.lua`，服务名 `.name`，协议号数字。
- 项目里已有的「反模式 / 红线」约定要显式写（例如「不要 `skynet.localname(".gate")`」「热路径不过全局服」），这些是新人最容易踩的。

## 发布前检查

- [ ] 提到的每个文件路径、服务名、协议号都能在代码里找到。
- [ ] 已登记进 `docs/README.md` 索引。
- [ ] 与相关模块 README 口径一致，无重复内容。
- [ ] `reference/project-map.md` 的映射仍然准确。
