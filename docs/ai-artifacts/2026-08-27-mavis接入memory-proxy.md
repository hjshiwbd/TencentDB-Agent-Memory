# Mavis(MiniMax Code)接入 Memory Proxy 配置手册

> 适用场景:本机有 MiniMax Code 客户端,远程服务器部署了 TencentDB-Agent-Memory 的 Memory Proxy。  
> 目标:让 Mavis 的 LLM 调用走 proxy,自动注入 skill / knowledge / memory,对话回流到 Panel 可观测。  
> 经实测链路通的版本组合:Mavis v0.x + Memory Proxy v2.0.x + MiniMax 上游。

---

## 架构全景

```
[Mavis 客户端]                    [Memory Proxy]                    [MiniMax API]
  POST /codebuddy/default/v1/chat/completions
  Headers:                                │
    Authorization: Bearer <user_key>      │
    x-team-id    : team-...  ──────────►  │  校验 user_key → user_id
    x-agent-id   : agt-...   ──────────►  │  header 预选 team/agent/task
    x-task-id    : task-...  ──────────►  │  注入 skill + knowledge + memory 到 system prompt
    x-conversation-id: <会话标识>────────►  │  转发到上游
                                           │
                                  对话回流  │
                                           ▼
                                    [tidb 后端 / Panel UI 可见]
```

关键点:**Mavis 伪装成 codebuddy 客户端**(proxy 不在 7 个原生支持名单里,但 README §174-184 明确允许任意 OpenAI 兼容客户端伪装接入)。

---

## 前置条件

| 项 | 来源 |
|---|---|
| Memory Proxy 地址 + 端口 | 远程服务器,默认 `:8096`(健康端点 `/health`) |
| Panel 地址 + 端口 | 默认 `:8125`,需要能访问拿到 ID |
| `user_key`(API Key) | Panel 「用户 / API Key」页生成,`sk-mem-...` 开头 |
| `team_id` / `agent_id` / `task_id` | Panel 里建好 Team / Agent / Task 后,从详情页或 API 拿 |
| MiniMax Code 数据目录 | Windows 默认 `D:\minimax\.minimax\` |

---

## 步骤 1: 拿 4 个 ID

### 1a. 浏览器拿 ID(最简单)

浏览器开 Panel `http://<proxy-host>:8125`,登入后:
- 点 Team → 详情页里有 `team_id`
- 点 Agent → 详情页里有 `agent_id`
- 点 Task → 详情页里有 `task_id`(如果是 proxy 自动加的"本次不关联任务",ID 是 `no-task`)

### 1b. curl 拿 ID(本机可达 Panel 时)

```bash
USER_KEY="sk-mem-..."

# 1) 校验 + 拿 user_id
curl -s -X POST "http://<proxy-host>:8125/api/v1/meta/auth/verify" \
  -H "Content-Type: application/json" \
  -H "x-tdai-service-id: default" \
  -d "{\"user_key\":\"$USER_KEY\"}" | jq '.data.user.user_id'

# 2) 拉 Team
curl -s -X POST "http://<proxy-host>:8125/api/v1/meta/team/list" \
  -H "Content-Type: application/json" \
  -H "x-tdai-user-key: $USER_KEY" \
  -H "x-tdai-service-id: default" \
  -d "{\"user_key\":\"$USER_KEY\"}" | jq '.data.items[].team_id'

# 3) 拉 Agent(填上一步拿到的 team_id)
curl -s -X POST "http://<proxy-host>:8125/api/v1/meta/agent/list" \
  -H "Content-Type: application/json" \
  -H "x-tdai-user-key: $USER_KEY" \
  -H "x-tdai-service-id: default" \
  -d "{\"team_id\":\"<team_id>\",\"user_key\":\"$USER_KEY\",\"owner_user_id\":\"<user_id>\"}" \
  | jq '.data.items[].agent_id'

# 4) 拉 Task
curl -s -X POST "http://<proxy-host>:8125/api/v1/meta/task/list" \
  -H "Content-Type: application/json" \
  -H "x-tdai-user-key: $USER_KEY" \
  -H "x-tdai-service-id: default" \
  -d "{\"team_id\":\"<team_id>\",\"user_key\":\"$USER_KEY\"}" \
  | jq '.data.items[].task_id'
```

### 1c. 本机不可达 Panel 时

从能访问 Panel 的环境(浏览器 / 另一台机器 / VPN)拿完 ID,回来填下面 config 即可。proxy `:8096` 通常跟 Panel `:8125` 是同一台机器,但网络可达性可以不同。

---

## 步骤 2: 改 config.yaml

文件位置:`D:\minimax\.minimax\config.yaml`

改前先备份:

```bash
cp D:\minimax\.minimax\config.yaml D:\minimax\.minimax\config.yaml.bak.$(date +%Y%m%d_%H%M%S)
```

在 `custom_provider` 块下新增 `memory-proxy` 条目(不要覆盖其他条目):

```yaml
custom_provider:
  memory-proxy:
    name: tidb                          # 显示用,任意
    kind: custom
    enabled: true
    api: openai-completions             # 协议:OpenAI Chat Completions
    options:
      baseURL: http://<proxy-host>:8096/codebuddy/default/v1
      authMode: api-key
      apiKey: sk-mem-...                # Panel 拿的 user_key
      headers:
        x-team-id: team-...             # 4 个 ID
        x-agent-id: agt-...
        x-task-id: task-...
        x-conversation-id: mavis-static-conv001   # 见下文"会话隔离"
    models:
      MiniMax-M3:
        name: MiniMax-M3
        enabled: true
        attachment: true
        reasoning: true
        temperature: true
        tool_call: true
        limit:
          context: 512000
          output: 128000
        modalities:
          input: [text, image, video]
          output: [text]
```

**字段含义**:
- `name`:Panel 里看到的 provider 名字,可自定义
- `kind`:必须 `custom`
- `api`:协议,固定 `openai-completions`(Mavis 默认就是这套)
- `baseURL`:**伪装段** + spaceId。`/codebuddy/default/v1` 让 proxy 以为请求来自 codebuddy;`default` 是本地部署默认 spaceId
- `apiKey`:proxy user_key
- `headers`:4 个 header 必填,proxy 用这些做 header 预选(跳过交互式 form)
- `models.MiniMax-M3`:模型细节,跟 deepseek/jd 那些条目对齐

---

## 步骤 3: 验证 proxy 端通

```bash
curl -X POST "http://<proxy-host>:8096/codebuddy/default/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer sk-mem-..." \
  -H "x-team-id: team-..." \
  -H "x-agent-id: agt-..." \
  -H "x-task-id: task-..." \
  -H "x-conversation-id: my-verify-001" \
  -d '{"model":"MiniMax-M3","messages":[{"role":"user","content":"hi"}],"max_tokens":50}'
```

**期望结果**:
- HTTP 200
- 返回 id 是普通 UUID,**不是** `session-init-...`
- `usage.prompt_tokens` 在 2500-4000 区间(裸调基线约 184,差距说明 skill/knowledge/memory 注入了)
- 正常 assistant 回复

**异常判断**:
| 现象 | 原因 | 解决 |
|---|---|---|
| id 是 `session-init-...` + `ask_followup_question` tool_call | proxy 拿到部分 header,回退到交互式 form | 检查 `x-team-id`/`x-agent-id`/`x-task-id` 三个 header 是否填齐、值是否真实存在于 Panel |
| HTTP 401 + 空 body | proxy 路由不通 / user_key 无效 | 见下方"401 排错" |
| HTTP 401 + JSON `{"error":"Authentication failed: ..."}` | user_key 被 proxy auth/verify 拒绝 | 检查 user_key 是否有效,代理侧 `auth.enabled` 配置 |
| HTTP 502/503 | upstream LLM 不可达 | 检查 proxy `/health` 的 `upstream` 字段,确认上游 LLM 通 |

### 401 排错专项

跑这串诊断脚本,贴结果给写代码的人看:

```bash
# 1) 健康 + 版本
curl -s http://<proxy-host>:8096/health

# 2) 7 个 agent 路由全部探活(看哪个能用)
for agent in claude-code codebuddy workbuddy codex dsh hermes openclaw opencode; do
  status=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST "http://<proxy-host>:8096/${agent}/default/chat/completions" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer sk-mem-..." \
    -d '{"model":"x","messages":[{"role":"user","content":"x"}],"max_tokens":1}')
  echo "${agent}: HTTP ${status}"
done

# 3) dsh 详细 verbose(对比 codebuddy)
curl -sv -X POST "http://<proxy-host>:8096/dsh/default/chat/completions" \
  -H "Authorization: Bearer sk-mem-..." \
  -H "Content-Type: application/json" \
  -d '{"model":"x","messages":[]}' 2>&1 | grep -E '^[<>]'
```

预期 `codebuddy` 200、其他看路由是否在该 proxy 版本注册了。

---

## 步骤 4: 切 Mavis defaultModel(让对话实际走 proxy)

`D:\minimax\.minimax\config.yaml` 顶部 `defaultModel` 字段,改成:

```yaml
defaultModel: custom_provider:memory-proxy/MiniMax-M3
```

之后新开 Mavis 对话,实际请求就会走 proxy。**改之前 Mavis 还是走 jd/deepseek/那些,proxy 不会触发**。

不想切的话也无所谓——proxy 链路已经验证通,等你想用的时候再切。

---

## 会话隔离:`x-conversation-id` 的两种策略

| 策略 | 写法 | 行为 |
|---|---|---|
| **静态**(调试用) | `x-conversation-id: mavis-static-conv001` | 所有 Mavis 对话共享同一 proxy session,记忆/技能跨对话累积 |
| **动态**(推荐) | `x-conversation-id: ${MAVIS_SESSION}` | 每次新 Mavis 对话 = 新 proxy session,自动跟 Mavis 框架 session ID(以 `ses_` 开头)对齐 |

⚠️ `${MAVIS_SESSION}` 是 pi-coding-agent 框架的 env var 替换语法(`node_modules/@earendil-works/pi-coding-agent/dist/core/resolve-config-value.js`)。Mavis 内部是否真支持,需要在本机第一次跑 Mavis 时验证——如果走 proxy 拿到 `session-init-...` form 而不是正常 completion,说明替换没生效,回退到静态串。

---

## 已知踩坑

### 1. Panel :8125 跟 proxy :8096 可达性可能不同
这台机器访问 `:8125` 超时,但 `:8096` 可达。所以拿 ID 跟调 proxy 要分开处理:从能访问 Panel 的环境拿 ID,本机只调 proxy。

### 2. `x-task-id` 严格查表
proxy 在 `team.tasks` 里严格查 `x-task-id` 值,查不到就 mismatch。**没建过 task 又想跳过**,需要 proxy 端配 `sessionInit.defaultTaskId: "no-task"`,然后 header 用 `no-task`。改 proxy 端需要改 `MemoryProxy/deploy/global-images/start-proxy.sh` 模板并重启。

### 3. asset_confirm form 不会触发
proxy 默认会弹"是否关联团队资产?" form,要求客户端用 `ask_followup_question` tool 回答。Mavis 没这个 tool,所以**4 个 header 必填**,proxy header 预选自动跳过 form。

### 4. dsh 路由在某些版本不存在
`dsh` 路由在 proxy `v2.0.1-beta.1+` 才注册(`git log -S "/dsh/" -- MemoryProxy/src/server.ts`)。老版本没注册,会返回奇怪的 401。**用 codebuddy 最稳**(从 v0.x 开始就支持)。

### 5. proxy `/health` 版本号是假的
`server.ts:90` 硬编码 `version: "0.2.0"`,实际可能是 v2.0.x。**别用 `/health` 判断版本**——靠 git log / docker image tag。

### 6. Mavis 默认 proxy + fallback 模式
Mavis 自身的 proxy 配置(`options.baseURL`)指向 `/codebuddy/default/v1`,**当前默认 model 还是 jd/deepseek 那些**,proxy 不会触发。要主动切 `defaultModel` 才会用上。

---

## 回滚

如果新会话想恢复原状:

```bash
cp D:\minimax\.minimax\config.yaml.bak.<timestamp> D:\minimax\.minimax\config.yaml
```

或者只删 `custom_provider.memory-proxy` 整个块,其他不动。

---

## 相关引用

- proxy 项目入口:`D:\git\github\TencentDB-Agent-Memory\README_CN.md`
- 安装 + agent 接入文档:`INSTALL_CN.md` §"通过 Proxy 接入各类 Agent"
- "其他平台 + Header 预选(通用)"条款:`agents/README.md` §154-184
- 已知限制(`x-task-id` 必填、版本号 bug 等):`INSTALL_CN.md` §408-419
- 本次会话 handoff(含详细 debug log):`handoff-20260827-165836.md`

---

## 一句话总结

**改 `custom_provider.memory-proxy` 块,baseURL 伪装 codebuddy,4 个 header 填齐,curl 验 200 即可。** 切 defaultModel 才真正让 Mavis 走 proxy。