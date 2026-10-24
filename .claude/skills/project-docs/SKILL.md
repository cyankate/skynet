---
name: project-docs
description: 维护本 skynet Lua 游戏服务端的文档目录 docs/。当需要整理/编写/更新项目文档、给新开发者写上手文档、或根据当前代码改动（git diff / 最近提交）同步更新或新增文档时使用。触发词如「整理文档」「写文档」「更新文档」「补文档」「根据这次改动/提交同步文档」「给新人写上手文档」。
---

# 项目文档维护

目标是让 `docs/` 成为新开发者上手这个项目的第一入口：先看架构，再按模块深入。
维护范围是 `docs/` 总览层 + 各 `script/*/README.md` 模块深度层（两层见 `reference/structure.md`）。

## 开始前必读

1. `docs/README.md` —— 当前文档索引和已有内容。
2. `reference/structure.md` —— 文档分层、目录规范、模板、风格、发布前检查。
3. `reference/project-map.md` —— 「代码 → 文档」映射表和关键背景事实，用来定位改动该落到哪个文档。

## 流程 A：根据代码改动同步文档（最常用）

当用户说「根据这次改动/提交更新文档」时：

1. 取改动范围：
   - 未提交：`git diff --stat` + `git diff --name-only`
   - 已提交：`git log --oneline -n 20`，需要细节时 `git show --stat <commit>`
   - 或 `git diff HEAD~n --stat` 看最近 n 次
2. 把改动文件路径对照 `reference/project-map.md` 的「代码 → 文档」表，列出受影响的文档章节。
3. 逐个章节核对：**读对应代码的最新实现**，不要凭旧文档或记忆直接写，避免文档落后于代码。
4. 更新现有文档；若改动是全新模块/主题且没有对应章节，按 `reference/structure.md` 模板新增文档，并登记进 `docs/README.md` 索引。
5. 新增/移动/重命名了目录或服务时，同步更新 `reference/project-map.md` 的映射。
6. 收尾按 `reference/structure.md` 的「发布前检查」逐项过。

注意：
- 已有模块级 README（`script/cluster/README.md`、`script/map/README.md`、`script/map/MAINTAIN.md`、`script/security/README.md`）是深度文档，`docs/` 是总览层。总览里**引用**它们，不要复制内容；只有「总览层该有、现有文档又没有」的才在 `docs/` 新写。
- 一次改动若同时触及总览层和模块 README，两处都要更新，保持口径一致。

## 流程 B：从零写某个主题的文档

按 `reference/structure.md` 模板：先读代码 → 写 → 登记进 `docs/README.md` 索引。

## 流程 C：只看不写 / 回答「XX 在哪」

用 `reference/project-map.md` 快速定位并给用户指路即可，不要为此新建文档。

## 铁律

1. 文档必须来自代码事实，禁止臆测；拿不准就 `Read` / `Grep` 源码确认。
2. 中文书写，术语与已有文档一致（分片/shard、行军/march、门/gate、agent、locator、cluster、sproto）。
3. 一个文件讲清一件事；超过约 500 行的文档拆成多个，用 `docs/README.md` 串起来。
4. 不要删除或覆盖现有模块 README；只增补、引用、更新。
