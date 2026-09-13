# mothx API 文档

> 基于 `/Users/yangdongfeng/GoProjects/mothx` 源码整理，覆盖至 v1.2.95（含 v1.2.90 ~ v1.2.95 的 API 变化）。
>
> 本文档覆盖 mothx `serve` 模式注册的 HTTP API、WebSocket API，以及 OpenAI 兼容 API。接口默认由 `mothx serve` 提供。

## 1. 服务入口

启动服务：

```bash
mothx serve
# 或指定监听地址
mothx serve --port 8080
```

默认地址和配置由 `serve.json` / 全局设置决定。启动日志会显示 OpenAI API 地址，例如：

```text
http://127.0.0.1:7872/v1/chat/completions
```

### 认证

当 serve 配置启用认证时，HTTP API 使用 Bearer Token：

```http
Authorization: Bearer <token>
```

Web UI 登录接口使用配置的 token 作为密码，并通过 HttpOnly Cookie 建立浏览器会话。具体认证接口见第 3 节。

标准错误通常为 JSON；OpenAI API 错误格式示例：

```json
{
  "error": {
    "message": "...",
    "type": "invalid_request_error",
    "code": "..."
  }
}
```

---

## 2. Web UI 认证 API

当服务启用 Web UI/API 认证时使用以下接口。登录成功后服务端创建 HttpOnly 浏览器 session Cookie；接口不会返回或泄露配置中的 token。

### `POST /api/auth/login`

使用配置的 API token 作为密码登录。

请求体：

```json
{"password":"<api-token>"}
```

### `GET /api/auth/status`

查询当前浏览器 Cookie 是否已认证。响应只表示认证状态，不返回 token。

### `POST /api/auth/logout`

清除当前浏览器认证 Cookie。

---

## 3. OpenAI 兼容 API

这些接口在 `internal/serve/openaiapi/server.go` 中注册。设置 `DisableAPI` 后，以下 `/v1/*` 和部分 `/api/*` 接口不会注册。

### 2.1 健康检查

#### `GET /health`

返回服务健康状态。无需 API 功能开关；认证行为取决于服务配置。

响应类型：`HealthResponse`

```json
{
  "status": "ok",
  "version": "1.2.95",
  "sessions": 3
}
```

`version` 为服务版本号，`sessions` 为当前活动的 session 数量。

### 2.2 模型列表

#### `GET /v1/models`

返回当前 mothx 可用模型，响应兼容 OpenAI Models API。

响应类型：`ModelListResponse`

```json
{
  "object": "list",
  "data": [
    {
      "id": "model-id",
      "object": "model",
      "created": 0,
      "owned_by": "mothx",
      "provider": "provider-name",
      "input": ["text", "image"]
    }
  ]
}
```

v1.2.95 起每个模型返回所属 `provider`（厂商）字段，`input` 列出模型支持的输入模态（text/image/audio/video/file 等）。

### 2.3 Chat Completions

#### `POST /v1/chat/completions`

OpenAI Chat Completions 兼容接口。支持普通 JSON 响应和 SSE 流式响应。

请求体：

```json
{
  "model": "model-id",
  "messages": [
    {"role": "user", "content": "请检查这个项目"}
  ],
  "stream": true,
  "temperature": 0.2,
  "top_p": 0.9,
  "max_tokens": 4096,
  "x_background": false
}
```

字段：

| 字段 | 类型 | 必填 | 说明 |
|---|---|---:|---|
| `model` | string | 否 | 模型 ID；未提供时使用服务默认模型。支持 `provider/model` 限定 ID，例如 `openai/gpt-4o`（见 3.4 节） |
| `messages` | array | 是 | OpenAI 消息数组，支持字符串内容及多模态内容数组 |
| `stream` | boolean | 否 | 是否使用 SSE 流式返回 |
| `temperature` | number | 否 | 采样温度 |
| `top_p` | number | 否 | nucleus sampling 参数 |
| `max_tokens` | integer | 否 | 最大输出 token 数 |
| `x_background` | boolean | 否 | 是否创建可持久化的后台 Responses run |

非流式响应示例：

```json
{
  "id": "chatcmpl-...",
  "object": "chat.completion",
  "created": 0,
  "model": "model-id",
  "choices": [
    {
      "index": 0,
      "message": {"role": "assistant", "content": "..."},
      "finish_reason": "stop"
    }
  ],
  "usage": {
    "prompt_tokens": 0,
    "completion_tokens": 0,
    "total_tokens": 0
  }
}
```

流式响应为 `text/event-stream`，发送 OpenAI `chat.completion.chunk`，并可能发送 mothx 扩展事件：

- `tool_status`：工具调用状态
- `transcript`：Web UI transcript 投影
- `hosted_item`：托管工具生命周期投影
- `done`：流结束

### 2.4 Provider 模型探测

#### `GET /api/provider/models`

查询指定 provider 配置可用的模型。查询参数和 provider 配置由当前 serve 实现决定。

#### `POST /api/provider/test`

测试 provider/model 配置，不会自动将草稿配置持久化。

请求体核心字段：

```json
{
  "provider": "openai",
  "model": "model-id",
  "apiKey": "...",
  "baseURL": "https://api.example.com/v1"
}
```

> 不要在日志、文档或客户端源码中硬编码 API Key。

### 2.5 持久化 Run

#### `GET /api/runs/{runID}`

查询 durable run 的状态、会话、模型、模式、时间、错误、usage、上下文使用量和最后事件序号。

#### `POST /api/runs/{runID}/cancel`

请求取消指定 run。成功通常返回 HTTP `202` 和更新后的 run 视图。

#### `POST /api/runs/{runID}/retry`

对已终止的 run 创建一次关联的新 attempt。重试使用已持久化的原始 intent，客户端不能通过该接口替换 prompt 或执行策略。

### 2.6 附件

#### `GET /api/attachments/{providerRef}?session_id={sessionID}`

下载当前 session 消息归档中已授权的 provider 文件引用。不会代理任意 provider ID 或任意 URL。

### 2.7 Responses 后台 Run

这些接口要求当前 provider 支持 Responses background runs，并要求 `session_id` 查询参数。

#### `GET /api/responses/runs/{localRunID}?session_id={sessionID}`

查询本地 durable Responses run。

#### `POST /api/responses/runs/{localRunID}/cancel?session_id={sessionID}`

取消远端 Responses run。

#### `POST /api/responses/runs/{localRunID}/reconnect?session_id={sessionID}`

重新连接仍可恢复的后台 run。

#### `POST /api/responses/runs/{localRunID}/abandon?session_id={sessionID}`

放弃本地对后台 run 的继续管理。

#### `POST /api/responses/runs/{localRunID}/recover?session_id={sessionID}`

恢复可恢复的后台 run。部分场景要求请求体确认信息，例如：

```json
{
  "confirm": true,
  "toolCallIds": ["call-1"]
}
```

### 2.8 ESM 控制

ESM 是 Web UI 的图形化执行目标控制接口。

#### `GET /api/sessions/{sessionID}/esm`

读取 ESM 状态。

#### `POST /api/sessions/{sessionID}/esm`

创建 ESM 目标。

```json
{
  "objective": "运行测试并修复失败项",
  "tokenBudget": 10000,
  "version": "当前版本号"
}
```

#### `PATCH /api/sessions/{sessionID}/esm`

修改 objective 或 token budget。

#### `DELETE /api/sessions/{sessionID}/esm`

清除 ESM 目标。

#### `POST /api/sessions/{sessionID}/esm/guidance`

追加指导：

```json
{"guidance":"优先运行单元测试","version":"..."}
```

#### `POST /api/sessions/{sessionID}/esm/pause`

暂停 ESM。

#### `POST /api/sessions/{sessionID}/esm/resume`

恢复 ESM。

#### `PATCH /api/sessions/{sessionID}/esm/budget`

单独修改 token budget：

```json
{"tokenBudget":10000,"version":"..."}
```

---

## 4. 服务管理 API

这些接口由 `internal/serve/run.go` 注册，主要供 mothx Web UI 使用。

### 3.1 服务和能力

| 方法 | 路径 | 说明 |
|---|---|---|
| `GET` | `/api/status` | 服务、运行时和连接状态 |
| `GET` | `/api/capabilities` | 服务级模式、能力可用性和默认值 |
| `GET` | `/api/channels` | WeChat、Feishu 等 channel 状态 |
| `GET` | `/api/session-tools/catalog` | 当前 session/channel 工具目录 |
| `GET` | `/api/session-bindings` | 所有 session/channel 绑定 |

### 3.2 Session 列表和生命周期

#### `POST /api/session-id`

服务端分配会话 ID（v1.2.91 新增）。Web UI 通过该接口请求规范统一的会话 ID，而非在浏览器端生成；服务端会去重并清理过期保留。

响应：

```json
{"sessionId": "session-id"}
```

#### `GET /api/sessions`

列出 session。

查询参数：

| 参数 | 说明 |
|---|---|
| `scope=all\|active` | 默认 `all`；`active` 只返回活动 session |
| `limit` | 大于 0 时启用数据库分页 |
| `offset` | 分页偏移 |
| `search` | 分页查询时按消息/会话搜索 |

分页响应：

```json
{"sessions": [], "total": 0}
```

v1.2.92 起 session 列表项包含会话分叉字段：`parentSessionId`、`forkBoundarySeq`、`seedLength`、`forkKind`（非分叉会话这些字段为空）。使用已存在的 ID 创建会话会失败并返回 `ErrSessionIDExists`（`409`），不会再将新头部静默合并进旧会话。

#### `GET /api/sessions/active`

只返回当前活动 session。

#### `DELETE /api/sessions/{sessionID}`

删除 session，并关闭其运行时资源。活动 run、绑定冲突等情况可能返回 `409`。

#### `POST /api/sessions/{sessionID}/title`

设置 session 标题：

```json
{"title":"项目测试"}
```

#### `PATCH /api/sessions/{sessionID}/metadata`

更新 project 归属和置顶状态：

```json
{"projectId":"project-id","pinned":true}
```

#### `POST /api/sessions/{sessionID}/fork`

从任意消息序号分叉出替代分支（v1.2.92 新增）。分叉会复制会话快照并创建新的子会话，源会话保持只读边界。

请求头必须携带幂等键（长度 1~256）：

```http
Idempotency-Key: unique-fork-request-id
```

请求体（均可选）：

```json
{
  "atSeq": 42,
  "titleMode": "increment"
}
```

- `atSeq`：分叉边界消息序号；不提供时取最后一个已完成回合
- `titleMode`：子会话标题模式，默认 `increment`

成功响应：

```json
{
  "sessionId": "child-session",
  "parentSessionId": "source-session",
  "forkKind": "session",
  "boundarySeq": 42,
  "seedLength": 10
}
```

`forkKind` 取值：`session`（会话级分叉）、`message`（消息级分叉）。

错误码（`code` 字段）：

| 状态码 | code | 说明 |
|---|---|---|
| `400` | `idempotency_key_required` / `idempotency_key_too_long` | 缺少幂等键或超长 |
| `400` | `invalid_boundary` | 分叉序号无效 |
| `404` | `session_not_found` | 源会话不存在 |
| `409` | `idempotency_key_conflict` | 相同幂等键但请求指纹不一致 |
| `409` | `no_completed_turn` | 没有可分的已完成回合 |
| `409` | `session_active` / `fork_unavailable` / `session_modified` / `session_lease_lost` | 会话活跃或状态不允许分叉 |

### 3.3 Session 消息和历史

| 方法 | 路径 | 说明 |
|---|---|---|
| `GET` | `/api/sessions/{sessionID}/messages` | 读取消息历史 |
| `GET` | `/api/sessions/{sessionID}/messages?limit=N` | 读取最近 N 条 |
| `GET` | `/api/sessions/{sessionID}/messages?before=SEQ&limit=N` | 读取指定序号前的消息 |
| `GET` | `/api/sessions/{sessionID}/stream` | SSE session 流 |
| `GET` | `/api/sessions/{sessionID}/run-events` | 读取持久化 run 生命周期事件 |
| `GET` | `/api/sessions/{sessionID}/capability-events` | 读取能力变更事件 |
| `GET` | `/api/sessions/{sessionID}/tool-results/{toolCallID}` | 读取工具调用完整结果 |
| `GET` | `/api/sessions/{sessionID}/subagents` | 读取子 Agent 列表 |
| `GET` | `/api/sessions/{sessionID}/subagents/{agentID}/messages` | 读取子 Agent transcript |
| `GET` | `/api/sessions/{sessionID}/trajectory` | 只读轨迹投影（v1.2.92 新增） |
| `GET` / `HEAD` | `/api/sessions/{sessionID}/export` | 会话日志导出，NDJSON 格式（v1.2.92 新增） |

消息分页响应形如：

```json
{"messages": [], "hasMore": false}
```

#### `GET /api/sessions/{sessionID}/trajectory`

只读轨迹投影：将消息、持久化 run 事件和能力变更事件按时间线统一组织，不复制 Agent/Runtime 状态。

查询参数：

| 参数 | 说明 |
|---|---|
| `before` | 游标（base64url 编码的 JSON），只返回指定序号之前的记录 |
| `limit` | 返回条数上限，默认 200，最大 500 |

响应类型：`SessionTrajectoryResponse`

```json
{
  "sessionId": "session-id",
  "records": [
    {
      "id": "transcript:session-id:msg-1",
      "sessionId": "session-id",
      "parentSessionId": "",
      "seq": 1,
      "source": "transcript",
      "kind": "user",
      "status": "completed",
      "role": "user",
      "summary": "请检查这个项目",
      "preview": "请检查这个项目"
    }
  ],
  "highWater": {"entrySeq": 12, "runSeq": 5, "capabilitySeq": 2, "decisionSeq": 1},
  "hasMore": false
}
```

`records` 中每条记录按 `source` 区分：`transcript`（消息）、`run`（run 生命周期/快照）、`decision`（approval/question 决策）、`capability`（能力变更事件）；`highWater` 为各来源当前最大序号，可用作下一次 `before` 游标。

游标格式（base64url(JSON)）：

```json
{"entrySeq": 12, "runSeq": 5, "capabilitySeq": 2, "decisionSeq": 1}
```

错误：`404` session 不存在；`400` 游标无效（`invalid trajectory cursor`）。

#### `GET /api/sessions/{sessionID}/export`

以 NDJSON 流式导出会话日志（`application/x-ndjson`），支持 `HEAD` 预检。首个记录为 manifest：

```json
{"schemaVersion":1,"type":"manifest","sessionId":"session-id","generatedAt":"...","includeDescendants":true,"sessionCount":1}
```

查询参数：

| 参数 | 说明 |
|---|---|
| `format` | 仅支持 `log`（默认） |
| `include_descendants` | 是否包含子会话（分叉后代），默认 `true` |

响应头包含 `X-Mothx-Session-Count`（导出会话数）和 `Content-Disposition` 附件文件名 `<session>.log`。

### 3.4 Session Run

#### `GET /api/sessions/{sessionID}/runs?limit=100`

读取 session 的历史 runs。响应为 `{ "sessionId": "...", "runs": [...] }`，**最新在前**。
客户端消费的字段（Go 结构体字段名，无 json tag，故为 PascalCase）：

| 字段 | 说明 |
|---|---|
| `ID` | Run id。客户端据此推导该轮的用户 entry：`run-user-<ID>` |
| `IntentID` | 一次提交意图；重试共享同一 intent，客户端按它保留最新 attempt |
| `RetryOf` | 重试的父 Run id；用于回溯到根 Run 以还原所属轮次 |
| `Status` / `Error` | 轮次状态与错误 |
| `StartedAt` / `FinishedAt` / `UpdatedAt` | 轮次耗时（`FinishedAt` 空则用 `UpdatedAt`） |

约定（客户端依赖）：一轮对话 Run 的 user entry id 为确定性 `run-user-<runID>`，即转录 `GET /messages` 里该轮 user 消息的 `id`，也是轮次锚点；客户端**只按这个身份**把 Run 绑定到轮次，不按列表下标配对。

#### `POST /api/sessions/{sessionID}/runs`

提交一次 Agent 运行，接口立即返回后台 run 信息。

请求体：

```json
{
  "message": "运行测试并总结结果",
  "provider": "openai",
  "model": "gpt-4o",
  "mode": "yolo",
  "tools": ["shell", "read"],
  "skills": ["go-testing"],
  "images": ["data:image/png;base64,..."],
  "transcript": true,
  "workDir": "/path/to/project"
}
```

字段：

| 字段 | 类型 | 说明 |
|---|---|---|
| `message` | string | 文本任务；与 `images` 至少提供一个 |
| `provider` | string | 按运行选择的厂商（v1.2.95 新增）；不指定时使用服务默认厂商 |
| `model` | string | 指定模型；支持 `provider/model` 限定 ID，服务端会解析并校验厂商与模型是否匹配 |
| `mode` | string | 执行模式，如 `agent`、`plan`、`yolo` |
| `tools` | string[] | 请求使用的工具 |
| `skills` | string[] | 激活的 skills |
| `images` | string[] | base64 data URL 图片 |
| `transcript` | boolean | 是否产生 transcript 投影 |
| `workDir` | string | 工作目录，受服务安全策略限制 |

建议提供幂等请求头：

```http
Idempotency-Key: unique-client-request-id
```

厂商校验失败时返回结构化错误（`type: invalid_request_error`）：

- `invalid_model`（400）：限定模型无法解析
- `provider_model_mismatch`（400）：请求的厂商不拥有所选模型，例如 `provider=openai` 但模型实际属于 Anthropic

#### `POST /api/sessions/{sessionID}/stop`

停止当前 session run，返回 `cancellation_requested`。

#### `GET /api/sessions/{sessionID}/runtime`

读取 session 当前运行时快照，包括 mode、model、capabilities、待处理 approval/question 和 active run。

#### `PATCH /api/sessions/{sessionID}/runtime`

更新 session runtime：

```json
{
  "mode": "agent",
  "displayMode": "agent",
  "capabilities": {
    "browser": true,
    "delegate": false
  },
  "tools": {
    "webSearch": true,
    "browser": true,
    "delegate": false,
    "multiAgent": false,
    "workflows": true
  }
}
```

#### `GET /api/sessions/{sessionID}/capabilities`

读取 session 有效能力。

#### `PATCH /api/sessions/{sessionID}/capabilities`

更新 session 能力。可更新字段包括：`mode`、`displayMode`、`delegateMode`、`delegate`、`multiAgent`、`workflows`、`webSearch`、`browser`、`a2aMaster`。

### 3.5 Approval 和 Question

#### `POST /api/sessions/{sessionID}/approvals/{approvalID}`

提交工具/命令审批结果。请求体类型：

```json
{
  "approved": true,
  "always": false
}
```

实际字段以 `SessionApprovalResponse` 为准。

#### `POST /api/sessions/{sessionID}/questions/{questionID}`

回答 Agent 问题：

```json
{"answer":"继续"}
```

### 3.6 Session 绑定

#### `POST /api/sessions/{sessionID}/bindings`

绑定到 channel：

```json
{"channelType":"wechat","channelId":"user-or-conversation-id"}
```

#### `PUT /api/sessions/{sessionID}/bindings`

转移 channel 绑定：

```json
{
  "channelType": "wechat",
  "channelId": "conversation-id",
  "fromSessionId": "old-session",
  "toSessionId": "new-session"
}
```

#### `DELETE /api/sessions/{sessionID}/bindings`

解除绑定并恢复为本地 session。

#### `GET /api/sessions/{sessionID}/channel-tools`

读取 WeChat/Feishu session 的 channel 工具状态。

#### `PUT /api/sessions/{sessionID}/channel-tools`

替换完整工具选择列表：

```json
{"tools":[{"name":"shell","enabled":true}]}
```

### 3.7 Session MCP

#### `/api/sessions/{sessionID}/mcp`

用于读取或修改 session 级 MCP 配置，支持的方法和字段由 `handleSessionMCPConfig` 实现；服务级 MCP 配置见 `/api/mcp`。

---

## 5. 配置、项目和运行环境 API

| 方法 | 路径 | 说明 |
|---|---|---|
| `GET` | `/api/settings` | 读取全局 settings.json 配置 |
| `PUT` | `/api/settings` | 保存全局 settings 并应用到运行时 |
| `GET` | `/api/serve/config` | 读取 serve.json |
| `PUT` | `/api/serve/config` | 保存 serve 配置 |
| `PATCH` | `/api/serve/config/channels/{platform}` | 修改 channel 配置 |
| `GET` | `/api/env` | 读取 mothx 环境变量配置 |
| `PUT` | `/api/env` | 保存环境变量配置 |
| `GET` | `/api/memory` | 读取 Memory 内容 |
| `PUT` | `/api/memory` | 写入 Memory 内容 |
| `GET` | `/api/browse?path=...` | 浏览允许范围内的目录 |
| `POST` | `/api/select-directory` | 弹出操作系统原生目录选择器（v1.2.92 新增） |
| `GET` | `/api/mcp` | 读取 MCP 配置 |
| `PUT` | `/api/mcp` | 写入 MCP 配置 |

全局设置（settings.json）v1.2.92 起新增 `authored`（默认关闭）：启用后系统提示附加 MothX 共同作者标记，引导模型在 git 提交中包含 `Co-Authored-By: MothX <harness@mothx.net>`。

> v1.2.92 起新安装和空 mode 回退的默认模式改为 `yolo`（此前为 `agent`）；显式 `--mode`、已持久化的会话 mode 以及微信/飞书强制 `yolo` 仍然优先，已有配置中的 `defaultMode: "agent"` 不会被改写。

Memory 写入请求：

```json
{"content":"# Project memory\n\n..."}
```

目录浏览只返回目录，不返回普通文件；路径受到 workdir/allowed workdirs 安全限制。

#### `POST /api/select-directory`

调用操作系统原生目录选择器（macOS/Windows/Unix）选择工作目录，替代手动输入路径。请求体：

```json
{"defaultPath": "/path/to/start"}
```

`defaultPath` 可选，缺省使用服务 workdir。成功响应：

```json
{"canceled": false, "path": "/Users/me/selected"}
```

用户取消时返回 `{"canceled": true, "path": ""}`；选择器不可用时返回 `501`。

### Projects

#### `GET /api/projects`

列出项目。

#### `POST /api/projects`

创建项目：

```json
{"name":"mothx"}
```

#### `PATCH /api/projects/{projectID}`

重命名项目：

```json
{"name":"new-name"}
```

#### `DELETE /api/projects/{projectID}`

删除项目。

桌面端启动和手动刷新会读取该项目列表，并将本地保存的工作目录与远端项目 ID 合并；工作目录不是 mothx 项目 API 的字段。

### Stats

#### `GET /api/stats/summary`

读取统计摘要。

#### `GET /api/stats/by-model`

按模型读取统计。

`/api/stats/` 后续路径会被统计 handler 解析，具体可用 endpoint 以 `internal/stats` 查询实现为准。

---

## 6. Cron 定时任务 API

#### `GET /api/cron`

返回 cron 是否启用、是否运行、配置路径和任务列表。可通过 `sessionId` 查询某个 session 的任务。

#### `POST /api/cron`

创建任务。

必填字段：`sessionId`、`name`、`prompt`。

可选字段：

```json
{
  "sessionId":"session-id",
  "name":"daily-test",
  "prompt":"运行测试并汇总",
  "schedule":"@daily",
  "oneshot":false,
  "mode":"yolo",
  "workDir":"/path/to/project",
  "a2aTarget":"https://remote.example/a2a",
  "a2aToken":"...",
  "enabled":true
}
```

#### `PATCH /api/cron/{jobID}` 或 `PUT /api/cron/{jobID}`

更新任务字段。

#### `DELETE /api/cron/{jobID}`

删除任务。

---

## 7. SkillHub API

所有路径前缀为 `/api/skillhub`。

| 方法 | 路径 | 说明 |
|---|---|---|
| `GET` | `/api/skillhub/markets` | 市场列表 |
| `GET` | `/api/skillhub/categories` | 分类列表 |
| `GET` | `/api/skillhub/official` | 官方 skills |
| `GET` | `/api/skillhub/search` | 搜索 skills |
| `GET` | `/api/skillhub/skills/{skillID}` | skill 详情 |
| `GET` | `/api/skillhub/targets` | 安装目标 |
| `GET` | `/api/skillhub/installed` | 已安装 skills |
| `POST` | `/api/skillhub/install` | 安装 skill |
| `POST` | `/api/skillhub/activate` | 激活 skill |
| `POST` | `/api/skillhub/set-active` | 设置活动状态 |
| `POST` | `/api/skillhub/skillset` | 管理 skillset |
| `POST` | `/api/skillhub/uninstall` | 卸载 skill |
| `GET` | `/api/skillhub/showcase/{id}` | showcase 内容 |
| `GET` | `/api/skillhub/content/{id}` | skill 内容 |

搜索、安装、激活等请求的字段由 SkillHub service 对应 handler 校验；常用查询参数包括 `market`、`sessionId`、`workDir`。

---

## 8. Channel 和微信登录 API

### Channel 状态

#### `GET /api/channels`

返回各消息渠道启用和连接状态。

### 微信登录

#### `GET /api/channels/wechat/login`

读取当前登录状态。

#### `POST /api/channels/wechat/login`

启动微信登录，返回 `202 Accepted` 和二维码状态。

#### `DELETE /api/channels/wechat/login`

取消当前登录流程。

#### `GET /api/channels/wechat/login/qr`

代理读取当前二维码图片。

查询参数：`format=base64` 时返回 base64 格式数据。

响应示例：

```json
{
  "dataUrl": "data:image/png;base64,...",
  "base64": "...",
  "contentType": "image/png"
}
```

---

## 9. WebSocket API

### `WebSocket /ws/runs`

用于 Web UI 订阅 session/run 事件。断开连接只会取消订阅，不会取消运行中的 Agent。

连接后发送：

```json
{"type":"hello","clientId":"desktop-ui"}
```

服务端响应：

```json
{"type":"ready","protocol":1,"clientId":"desktop-ui"}
```

订阅：

```json
{
  "type":"subscribe",
  "subscriptions":[
    {
      "sessionId":"session-id",
      "cursor":{"seq":0}
    }
  ]
}
```

取消订阅：

```json
{"type":"unsubscribe","sessionIds":["session-id"]}
```

请求历史回放：

```json
{
  "type":"replay",
  "sessionId":"session-id",
  "cursor":{"seq":100}
}
```

事件 envelope：

```json
{
  "type":"event",
  "sessionId":"session-id",
  "runId":"run-id",
  "stream":"run",
  "event":"run_completed",
  "seq":101,
  "data":{}
}
```

运行过程中，服务端会在每次模型 Usage 更新时通过同一 WebSocket 推送累计 Usage：

```json
{
  "type":"session_event",
  "sessionId":"session-id",
  "runId":"run-id",
  "stream":"run",
  "event":"usage",
  "seq":102,
  "data":{
    "usage":{
      "prompt_tokens":1000,
      "completion_tokens":200,
      "total_tokens":1200,
      "cache_read_tokens":700,
      "cache_write_tokens":0
    }
  }
}
```

`usage` 是当前 Run 的累计值，不是单次 provider 请求的增量值；Run 结束后，最终值也会写入 Run 的持久化 Usage。客户端应使用 `runId` 严格匹配当前 Run，不能用其他 Run 的 Usage 作为回退数据。

> 重同步（v1.2.95）：事件代理引入了 `SubscribeWithResync`。正常取消订阅不会触发重同步；但当订阅者溢出（积压过多事件）时，服务端会直接关闭 WebSocket，客户端应重连并通过 durable SQLite 游标（`cursor`）重新回放，避免丢失实时状态。断开连接本身不会取消运行中的 Agent。

### `WebSocket /ws/logs`

接收服务管理日志和 channel 管理事件。消息格式由 `serveLogEvent` 投影定义，主要用于 Web UI 日志面板。

---

## 10. CLI 可调用入口

除了 HTTP API，源码还提供 Cobra CLI 子命令：

| 命令 | 用途 |
|---|---|
| `mothx serve` | 启动统一 HTTP/WebSocket/Web UI 服务 |
| `mothx init-config global` | 创建全局 serve.json 模板 |
| `mothx init-config project` | 创建项目 serve.json 模板 |
| `mothx stats` | 查看统计数据 |
| `mothx a2a` | A2A 相关能力 |
| `mothx doctor` | 环境诊断；v1.2.93 起支持 `--json` 输出机器可读诊断结果 |

> v1.2.95 起 CLI 的 `runPrint` 通过 `agentruntime.ExecutionRuntime` 持久化规范的 durable run，与 WebUI、消息通道和 ACP 的运行生命周期保持一致。

完整命令参数请运行：

```bash
mothx --help
mothx serve --help
mothx stats --help
mothx a2a --help
```

---

## 11. 源码依据与限制

主要依据：

- `internal/serve/openaiapi/server.go`：基础 OpenAI/API 路由
- `internal/serve/openaiapi/types.go`：请求、响应和能力类型
- `internal/serve/openaiapi/handler_chat.go`：chat completions 与 per-run provider 解析
- `internal/serve/openaiapi/handler_run_submit.go`：session run 提交（含 `provider` 字段与厂商/模型校验）
- `internal/serve/openaiapi/handler_session_trajectory.go`：session trajectory 与日志导出接口
- `internal/serve/openaiapi/run_api.go`：durable run API
- `internal/serve/openaiapi/responses_run_api.go`：Responses background run API
- `internal/serve/openaiapi/esm_handler.go`：ESM API
- `internal/serve/openaiapi/websocket.go`：`/ws/runs`（含 resync 溢出关闭）
- `internal/serve/run.go`：管理、session（含 fork、trajectory、export、session-id、select-directory）、项目、配置、cron、channel 等路由
- `internal/serve/mcp_api.go`：MCP 配置
- `internal/serve/skillhub.go`：SkillHub 路由
- `internal/serve/channels_api.go`：微信登录和 channel API

部分接口的 JSON schema 分散在内部 handler 的匿名 struct、provider adapter 或 SkillHub service 中，本文档列出已确认的路径和主要字段；如需将 macOS UI 做成完全动态的接口浏览器，建议后续在 mothx 服务端增加正式的 OpenAPI 文档端点，或由桌面端读取一份版本化 API schema。
