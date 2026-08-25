# `docs/ai-artifacts/` — AI 工作产出

> 本目录存放 AI 编码助手（Codex/Claude 等）在该仓库工作时产生的**非权威产出**：
> 探索笔记、决策记录、抓包分析、调研报告、一次性草稿等。

## ⚠️ 这不是权威文档

- 这里的内容由 AI 生成，**未经人工 review 前不应作为设计依据**
- 跟根目录的 `README.md` / `INSTALL.md` / `CHANGELOG.md` 不同，那些是仓库官方文档
- 内容可能过期、可能错、可能跟代码实际状态不符 — **永远以代码为准**

## 子目录约定

| 子目录 | 用途 | 例子 |
|---|---|---|
| `notes/` | 探索性笔记、抓包分析、技术调研、对话 handoff | `2026-08-23-tdai-mavis-handoff.md` |
| `decisions/` | ADR 风格决策记录（问题/需求/方案/决策）| `2026-08-23-mavis-extension-strategy.md` |
| `scratch/` | 一次性草稿、实验代码片段、临时分析 | (空) |

## 文件命名约定

**`YYYY-MM-DD-<slug>.md`**

- 日期前缀强调事件发生时间（不是顺序编号）
- slug 用 kebab-case，描述性强但简短
- 例：`2026-08-23-mavis-extension-strategy.md`

## 跟 upstream 合并

这些文件**只存在于本仓库**（分支 `minimax-mavis-support` 等），upstream 没有。当从 `feat/server_team` 拉新代码时：

- `docs/` 目录本身是新建的 → 0 冲突
- 子目录里的文件都是个人工作产物 → 0 冲突
- 即使上游某天建了 `docs/`（同名），里面的内容也跟我们这里的 AI 产物不冲突

## 何时清理

- 当某个决策已落地到代码、文档已迁移到 `INSTALL.md` 或 ADR 已沉淀，原文件可归档或删除
- `scratch/` 里的草稿可以定期清理
- `notes/` 里的 handoff 类文档在任务结束后通常可以删

---

**最后修改**: 2026-08-23
