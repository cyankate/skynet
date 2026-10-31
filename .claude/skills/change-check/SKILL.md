---
name: change-check
description: 改动自检——改完代码后（未提交或某次提交）跑一次 build，并对照 docs/dev-guide.md 的反模式清单检查 diff，提醒该同步的文档。触发词：「自检」「检查这次改动」「check 一下」「改动自检」。
---

# 改动自检

目标：改完代码后快速确认三件事——**能编译、没踩反模式、文档没落下**。只检查并报告，不擅自改代码。

## 开始前必读

1. `docs/dev-guide.md` 的「常见反模式（新人别踩）」——检查清单的权威来源。
2. `docs/README.md`——文档索引，用来判断改动是否要同步文档。

## 流程

1. 取改动范围：
   - 未提交：`git diff --stat` + `git diff --name-only`
   - 刚提交：`git show --stat HEAD`，或 `git diff HEAD~1 --stat`
2. 跑构建：`make`。失败就把关键报错 + 涉及的改动文件列出来。
3. 对照反模式清单逐条查 diff，至少覆盖这三条：
   - 有没有用 `skynet.localname(".gate" / ".locator" / ".shard.*")`？跨服务应走 `cluster.rpc` / `shard.addr`。
   - 分片下行走是否正确（`send_to_conn`，而不是拿 agent 记下的 gate handle 去 send）？
   - 热路径（移动 / 视野 / 战斗结算）有没有被路由进全局 map 服务？
4. 判断文档要不要同步：新增 / 改了服务、协议、存储、玩法时，对照 docs/README.md 索引判断，必要时让 `project-docs` skill 处理。
5. 输出简短清单：✅ 通过 / ⚠️ 问题（`文件:行` + 一句话）+ 需要同步的文档。

## 铁律

1. 只报告，不擅自改代码。
2. 反模式判断以 dev-guide.md 为准，拿不准就 Read 源码确认，别凭记忆。
3. `make` 失败要给出关键报错行，不要整段贴原始输出。
