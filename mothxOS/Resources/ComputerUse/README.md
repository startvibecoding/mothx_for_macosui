# mothxOS Computer Use MCP server

单文件、零依赖 Node（≥18）stdio MCP server，让 mothx Agent 通过既有 MCP 通路
操作本机 macOS 桌面：截图、点击、键入、按键、激活应用、读取窗口与辅助功能树。

- 协议：MCP stdio，换行分隔 JSON-RPC 2.0（protocolVersion `2025-11-25`）。
- 依赖：`screencapture` / `sips` / `osascript` / `pbcopy`（系统自带），
  `cliclick`（可选，`brew install cliclick`，用于 move/drag 与多键点击）。
- 版本：`// VERSION: 1`（`--version` 输出 `computer 1`）。

## 坐标契约（最重要的设计）

模型永远在「它看到的那张图」的像素空间里思考，换算全部由 server 完成：

1. `screenshot` 产出两张：`shot-NNN.png`（原始像素）与 `shot-NNN.view.png`
   （长边缩放到 ≤ `--view-long-edge`，默认 **1568**，允许 1024～2048，
   对应内置 `read` 的 `fast`(1024)/`auto`(1568)/`detail`(2048) 上限），
   同时维护 `latest.png` / `latest.view.png`。
2. server 计算并记住当前几何：`pointsPerViewPx = screenPointsWidth / viewWidth`。
3. `click`/`move`/`drag` 的 `x,y` 默认单位是 **view 图片像素**；
   可选 `space: "view" | "screen"`（`screen` 表示屏幕 points，专家用法）。
4. 每次结果都回带 `geometry`（`view_size`、`full_size`、`screen_points`、
   `scale`、`points_per_view_px`、`display_id`），便于模型自检和排查。

窗口截图（`-l`）时 view 图就是窗口内容，坐标系相对窗口左上角；传
`window_bounds`（或 `app` + `window_id` 让 server 用 System Events 读取）
时 `space:"screen"` 才会加上窗口偏移。

## 工具表

| 工具 | 参数 | 说明 |
| --- | --- | --- |
| `screenshot` | `display?` `region?{x,y,w,h}`（points）`window_id?` `app?` `window_bounds?` `label?` | `screencapture -x -o` + `sips` 生成 view；结果末尾带 `publish_artifact <view 相对路径>` 兼容客户端缩略图管道 |
| `click` | `x,y` `space?` `button?=left` `count?=1` `modifiers?[]` | 有 cliclick 用 `c:/dc:/tc:`；否则 System Events `click at`（仅左键） |
| `move` | `x,y` `space?` | cliclick `m:`；无 cliclick 降级为点击并回 `degraded:true` |
| `drag` | `from{x,y}` `to{x,y}` `space?` | 需要 cliclick（`dd:` + `du:`） |
| `type_text` | `text` `method?=auto\|keystroke\|clipboard` | 纯 ASCII 走 `keystroke`；含非 ASCII 默认走剪贴板（`pbcopy` + `⌘V`）避开输入法 |
| `key` | `key`（return/escape/tab/space/delete/方向键/f1-f16…）或 `code` `modifiers?[]` | `key code N using {…}`；内置 keycode 表 |
| `activate` | `app`（名称或 bundle id） | `tell application … to activate` |
| `apps` | — | 前台应用（`background only is false`）名称列表 |
| `windows` | `app?` `limit?=20` | 窗口 `{name, position, size}`，points；best-effort |
| `ax` | `app` `depth?=3` `limit?=200` `window?=1` | System Events 递归 AX 树（`role|title|description|position,size` 每行一节点），慢且脆，优先截图+像素点击 |

## 返回格式

成功：`{"ok":true,"action":…,"geometry":{…},"hint":"read(image_path, imageMode=\"detail\") to view"}`，
`screenshot` 额外在文本末尾输出一行 `publish_artifact .mothx/computer-use/shot-003.view.png`。

失败：`{"ok":false,"action":…,"error":"可操作的中文错误","stderr":…}`，`isError: true`。
常见错误文案已内建：屏幕录制权限、辅助功能权限（-1719）、workdir 缺失、未知按键、cliclick 缺失。

## 使用方式

```bash
# 自检（不需要 mothx；会真实截一张图）
node server.js --workdir /tmp/cu-test --selftest

# 手工 MCP 会话（stdin JSON-RPC）
printf '%s\n' \
 '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}' \
 '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
 '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"screenshot","arguments":{}}}' \
 | MOTHX_CU_WORKDIR=/tmp/cu-test node server.js
```

接入 mothx（项目级 `mcp.json`，由客户端 `MothxComputerUse.swift` 写入）：

```json
{
  "name": "computer",
  "type": "stdio",
  "command": "node",
  "args": ["/Users/<user>/Library/Application Support/mothx/computer-use/server.js"],
  "env": [
    { "name": "MOTHX_CU_WORKDIR", "value": "/abs/path/to/project" },
    { "name": "MOTHX_CU_CLICK_BACKEND", "value": "auto" }
  ]
}
```

要点：

- `command: "node"` 可解析：mothx 子进程 env = 登录 shell 环境，PATH 含 nvm bin。
- 工具名前缀为 `mcp_computer_*`（server 名 `computer`）。
- **不要**再往全局 `~/.mothx/mcp.json` 放同名 `computer` 条目，否则 ACP 路径
  会在 connect 阶段抛 `duplicate MCP server name` 硬错误。
- 生效时机：MCP 在会话首次 run 时连接；已缓存会话默认 idle TTL 1800s，
  安装后需新开会话（或等 TTL 过期）。

## 安全边界

- server 只写 `<workDir>/.mothx/computer-use/`，首次写入自动落 `.gitignore`（`*`）。
- 保留最近 40 张截图（`--keep` 可调），超出即删。
- 屏幕内容、键入文本**不写任何日志**；stderr 只含动作类型与尺寸。
- 默认不自动启用：只有用户在设置页点开关后才写配置。
