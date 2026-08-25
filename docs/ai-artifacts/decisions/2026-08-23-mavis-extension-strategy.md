# Mavis 接入策略：最小侵入 + 新目录扩展

> **Date**: 2026-08-23
> **Branch**: `minimax-mavis-support` (forked from `feat/server_team`)
> **Remote**: `origin → TencentCloud/TencentDB-Agent-Memory`
> **Goal**: 在不污染上游代码的前提下接 Mavis,且后续从 default 分支拉代码能快速合并

---

## 策略核心

**两阶段开发**:

1. **Phase 1**: 一次性 hook 投资 — 在 4 个现有文件加 ≤40 行注册 API
2. **Phase 2**: Mavis 主体 — 全部放在 `src/extensions/mavis/` 新目录

**关键原则**: Phase 1 之后,任何新 agent 的接入都不再修改现有文件,只新增 `src/extensions/<name>/` 目录。

---

## Phase 1: Hook 投资

### 修改现有文件(4 处,一次性)

| 文件 | 改动 | 行数 |
|---|---|---|
| `MemoryProxy/src/index.ts` | 加 `import "./extensions/loader.js"` | +1 |
| `MemoryProxy/src/agent-adapters/index.ts` | switch 加 registry fallback + 导出 `registerAgentAdapter()` | ~10 |
| `MemoryProxy/src/session/session-key.ts` | header 列表改 `Set` + 导出 `addSessionIdHeader()` | ~5 |
| `MemoryProxy/src/session/index.ts` | if-else post-process 改成 registry 迭代 + 迁移 workbuddy/dsh | ~25 |

### 新增 loader

`MemoryProxy/src/extensions/loader.ts` — 自动扫描 `extensions/*/register.ts`。

---

## Phase 2: Mavis 全部新文件

```
MemoryProxy/src/extensions/mavis/
├── register.ts     # 调 3 个注册 API
├── adapter.ts      # mavis adapter stub
├── form.ts         # ask_user form builder
└── index.ts        # exports
```

### register.ts 范例

```ts
import { registerAgentAdapter } from "../../agent-adapters/index.js";
import { addSessionIdHeader } from "../../session/session-key.js";
import { registerFormRenderer } from "../../session/index.js";
import { mavisAdapter } from "./adapter.js";
import { buildMavisFormResponse } from "./form.js";

registerAgentAdapter("mavis", mavisAdapter);
addSessionIdHeader("x-mavis-session-id");
registerFormRenderer("mavis", buildMavisFormResponse);
```

---

## 合并冲突分析

| 文件类型 | 冲突概率 | 备注 |
|---|---|---|
| Phase 1 改的 4 文件 | 低 | 一次性 hook,上游一般不重写 |
| `src/extensions/*`(新目录) | **零** | 上游无此目录 |
| `src/extensions/mavis/*` | **零** | 完全私有 |

**最坏情况**: 4 个文件有小冲突,逐个 review。Mavis 主体永远 0 冲突。

---

## 跟"直接修改"方案对比

| 维度 | 直接修改 | 本策略 |
|---|---|---|
| 现有文件改动数 | 4 | 4(Phase 1) |
| 未来加 agent 改的现有文件数 | 4 | **0** |
| 合并风险 | 高(每次新增改老文件) | 低(一次性投资) |
| 新增代码可见性 | 散落各处 | 集中在 `extensions/<name>/` |

---

## 未来扩展

加新 agent (例如 `my-internal-copilot`):

1. 新建 `src/extensions/my-internal-copilot/{register,adapter,form,index}.ts`
2. 在 register.ts 里调 3 个注册 API
3. **不修改任何现有文件**

完成。
