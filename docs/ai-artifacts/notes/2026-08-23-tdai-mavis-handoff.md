# Handoff: TencentDB Agent Memory + Mavis Integration

> **Generated**: 2026-08-23 (after session that ended with `$handoff`)
> **Focus**: Mavis (internal coding agent) → MemoryProxy integration analysis
> **Next session goal**: User's architectural decision on unification proposal is pending; pick up from the three options presented at end of last session.

---

## TL;DR

User wants to integrate **Mavis** (their internal coding agent, Anthropic protocol) with **MemoryProxy** (TencentDB Agent Memory's LLM proxy module). Goal: get Mavis sessions registered with team/agent/task and receive memory injection (L0/L1/L2/L3).

The repo has evolved significantly since we started. Latest version is **v2.0.1-beta.2** (was v2.0.0 when we began). Major changes relevant to Mavis:
- 3 new agent adapters added (codex, workbuddy, dsh)
- `debugForceIdentity` extended from CC-only to **all agents**
- Session ID whitelist expanded from 5 to 6 entries
- New `AgentProfile` injection system emerged

**Adding Mavis today requires just 1 line of code** (header whitelist), thanks to debugForceIdentity now being generic. User is considering three options for how tdai should handle future agents uniformly.

---

## Conversation Arc (chronological)

1. **Initial repo exploration** → wrote `AGENTS.md` (463 words, contributor guide)
2. **Project nature clarification** → user: "这是一个在codeagent和llm之间的中转" — clarified MemoryProxy is the proxy, but project has 4 modules
3. **INSTALL_CN.md deep-read** → identified ports (8420/8125/8424/8096), Team/Agent/Task model, L0→L3 layering
4. **Mavis reveal** via packet capture → found headers: `x-mavis-session-id`, `x-api-key`, `x-mavis-agent-id`, etc.
5. **MemoryProxy source analysis** → identified 4 blockers (session whitelist, bootstrap, form mismatch, header config)
6. **Wrote ADR** `2026-08-09-mavis-integration-deferred.md` (12.8 KB, 7 sections) — user decided to defer
7. **User asked to move MDs to /root** → failed (read-only at the time), copied to /tmp instead → both later cleared by system
8. **Local-run question** → identified proxy runs in Docker but tsx runs TS directly; `npm run dev:config` works on host
9. **Pull request on Aug 23** → v2.0.1-beta.2 has significant agent support improvements
10. **User's architectural insight**: tdai should provide unified support or simple customization hooks
11. **I proposed 3 options** — user invoked `$handoff` before deciding

---

## User's Pending Decision (CRITICAL for next agent)

Three options I presented at end of last session:

### Option 1: Write an RFC / design proposal
- Path: `MemoryProxy/docs/decisions/2026-08-23-agent-unification-rfc.md`
- Content: declarative agent configuration design (YAML-driven adapters)
- Effort: 2-3 hours
- Impact: long-term, gives tdai team a concrete proposal

### Option 2: Small PR — make session ID whitelist configurable (RECOMMENDED in last message)
- Path: modify `MemoryProxy/src/session/session-key.ts` + `config.ts` + `types.ts`
- Effort: ~30 min (3 files, ~10 lines)
- Impact: unblocks Mavis immediately, lays groundwork for declarative config
- This is what I marked as "(Recommended)"

### Option 3: Just discuss / no action
- User may have wanted to talk before deciding

**The next agent should ask the user which option they want** before doing anything substantive.

---

## Key Codebase References (use CodeGraph to navigate)

Primary paths the next agent will need:

| File | Purpose | Status |
|---|---|---|
| `MemoryProxy/src/agent-adapters/index.ts:24-39` | Adapter factory, 5 cases now | ✅ Exists |
| `MemoryProxy/src/session/session-key.ts:9-19` | Session ID whitelist (hardcoded) | ✅ Exists, 6 entries |
| `MemoryProxy/src/session/codebuddy/init.ts:670-710` | `debugForceIdentity` (now generic) | ✅ Exists |
| `MemoryProxy/src/session/claude-code/init.ts:582` | Original `debugForceIdentity` impl | ✅ Exists |
| `MemoryProxy/src/session/codex/` | Codex session init (form/index/pagination) | ✅ NEW |
| `MemoryProxy/src/session/dsh/` | DSH session init | ✅ NEW |
| `MemoryProxy/src/session/workbuddy/` | WorkBuddy session init | ✅ NEW |
| `MemoryProxy/src/codexHandler.ts` | Codex's dedicated handler (940+ lines) | ✅ NEW |
| `MemoryProxy/src/injection/agents/workbuddy/profile.ts` | AgentProfile pattern (new arch) | ✅ NEW |
| `MemoryProxy/config.example.yaml:64-67` | Codex example in upstream agents | ✅ Exists |
| `MemoryProxy/Dockerfile` | Multi-stage build, tsx direct exec | ✅ Exists |
| `deploy/global-images/start-proxy.sh` | Docker run, only mounts config (no src) | ✅ Exists |
| `MemoryProxy/scripts/proxy.sh` | Host-mode management script | ✅ Exists |
| `MemoryProxy/package.json` | `npm run dev:config` for hot-reload dev | ✅ Exists |

**Mavis-specific code that does NOT exist** (what would need to be added):
- `x-mavis-session-id` entry in `session-key.ts:14`
- `case "mavis"` in `agent-adapters/index.ts:24`
- `MemoryProxy/src/agent-adapters/mavis.ts` (stub OK initially)

---

## Mavis Technical Details (from earlier packet capture, redacted)

- **Protocol**: Anthropic Messages API (`/v1/messages`)
- **Auth**: `x-api-key: <user_key>` (Anthropic standard)
- **SDK**: Stainless-generated `@ai-sdk/anthropic` v0.91.1
- **Auto-injected headers**: `x-mavis-session-id`, `x-mavis-agent-id`, `x-mavis-timezone-offset`, `anthropic-dangerous-direct-browser-access`
- **Tool**: `ask_user` (Mavis's equivalent of CC's `AskUserQuestion`)
- **GUI config**: only 4 fields exposed (base_url / api_key / protocol / model) — no header config

User's `sk-mem-...` business user key works with proxy's existing auth (proxy supports both `Authorization: Bearer` and `x-api-key` per `MemoryProxy/src/server.ts:80-83`).

---

## Architecture Context

TencentDB Agent Memory is a 4-module monorepo:

```
MemoryCore/      Memory kernel: gateway, L0→L3 extraction pipeline, skill export, OpenClaw/Hermes plugins
MemoryPanel/     UI control panel (port 8125)
MemoryKnowledge/ Knowledge service: Wiki + CodeGraph (port 8424)
MemoryProxy/     LLM request proxy (port 8096) ← relevant to Mavis
sdk/memory-core/ TypeScript + Python SDKs
deploy/          Docker recipes (global-images/ for one-command stack)
assets/          Images, demo videos
```

**MemoryProxy URL convention**:
```
http://<host>:8096/<agent-source>/<spaceId>/v1/<endpoint>
```
- `<agent-source>`: any string (e.g., "claude-code", "codebuddy", "codex", "workbuddy", "dsh", "mavis")
- `<spaceId>`: local default is "default"
- `/v1/messages` for Anthropic, `/v1/chat/completions` for OpenAI

---

## What Already Happened (so next agent doesn't redo it)

- ✅ Repo explored, modules mapped
- ✅ Mavis headers captured (redacted from this doc for safety)
- ✅ MemoryProxy source code analyzed in depth
- ✅ Two MDs written and then deleted: `AGENTS.md` and `2026-08-09-mavis-integration-deferred.md`
- ✅ Three potential integration paths evaluated:
  1. mitmproxy injection (works but hacky)
  2. Local code change + `debugForceIdentity` config (now viable)
  3. Passthrough (no memory benefit)
- ✅ Latest code pulled (v2.0.1-beta.2) and analyzed with CodeGraph

**Do NOT recreate the deleted MDs without explicit user request.** Their content is summarized here for reference.

---

## Suggested Skills for Next Agent

- **`openai-docs`** — Codex uses OpenAI Responses API. Useful for understanding Codex's protocol details and Codex-style agent patterns.
- **`plugin-creator`** — If user picks Option 1 (RFC for declarative agent config), this skill helps structure the proposal.
- **`skill-creator`** — If new agent-specific skills emerge from this work.

## Suggested Tools (not skills, but available)

- **`codegraph_explore`** (CodeGraph MCP) — primary way to navigate this codebase. Used throughout the conversation for fast symbol/flow lookup. Default to this over grep/find.
- **`exec_command` with sandbox_permissions escalated** — for `git`, `mv`, `cp` ops if needed.

---

## Environment Context

- **Working dir**: `/data/git/TencentDB-Agent-Memory` (git repo, branch `feat/server_team`)
- **User**: root, Linux container, Asia/Shanghai timezone
- **Sandbox**: `danger-full-access` (was `workspace-write` earlier in original session; now fully unrestricted)
- **`/root`**: was read-only when first attempted, but mode change made it writable. Still not used as preferred location.
- **`/tmp`**: writable, but contents get cleared between sessions (earlier MDs were lost this way)
- **Date jump**: Aug 9 → Aug 15 → Aug 23 between sessions (system clock skew)

---

## Recommended First Actions for Next Agent

1. **Re-confirm current state** with `git status` and `git log --oneline -5`
2. **Verify whitelist status** by reading `MemoryProxy/src/session/session-key.ts` directly (the file may have changed)
3. **Ask user which option they want** (1, 2, or 3)
4. **Don't write any new files until option is chosen** — but be ready to act fast once decided
5. If user picks Option 2: the change is small enough to show the diff inline before writing
