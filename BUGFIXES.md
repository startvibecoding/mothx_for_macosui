# mothxOS 问题修复表（BUGFIXES）

更新时间：2026-09-13

本表是 **已修复问题** 的唯一登记处。目的只有一个：**已经修过的问题不再被后续改动重新破坏**。

## 使用规则（每次改代码都必须执行）

1. **修新问题前先查表**：在本表里搜索模块名 / 现象关键词。如果新问题与表中任一条目同源（同一文件、同一行为、同一契约），先读该条目的「修复要点」和「回归防护点」，避免用相反的方式再改一遍。
2. **评估回归面**：新改动会碰到条目里列出的关键文件时，必须显式回答一句「是否影响已修复问题」，并在提交信息里写明。回归检查清单见第 3 节。
3. **修复后必须登记**：追加一条新行（不要覆盖历史条目），补全现象 / 根因 / 修复 / 涉及文件 / 提交 / 验证方式。
4. **不许重复登记**：同一根因再次复发时，不新建条目，改为在保留原条目的前提下追加「复发记录」（日期 + 提交 + 为何被打破）。
5. **条目不删不改语义**：只允许补充，不允许把旧条目改成新含义，否则历史回归信息会丢失。

---

## 1. 修复记录表

| ID | 日期 | 模块 | 现象 | 根因 | 修复要点 | 关键文件 | 提交 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| BUG-0001 | 2026-08-25 | 更新 / 版本检测 | 版本检测误报、升级入口不可用 | 版本判断逻辑内联在 UI，且与运行时安装状态耦合 | 抽出 `RuntimeInstall`，版本判断与服务端安装/更新分离；`AboutSection` 改为消费服务端版本；新增更新进度面板 | `mothxOS/Utilities/RuntimeInstall.swift`、`Views/AboutSection.swift`、`Views/UpdateProgressSheet.swift`、`MothxServiceManager.swift` | `d0cf352` |
| BUG-0002 | 2026-08-30 | ACP 集成 | ACP 会话事件、状态、用量、文件变更解析多处错误 | 客户端没有独立 ACP 通道，事件/用量/变更混在旧 HTTP 逻辑里 | 新增 `MothxACPClient`、`MothxACPUsageReader`；重写 `StatusInline`；按 ACP 修正 Run 汇总与文件变更解析 | `MothxACPClient.swift`、`MothxACPUsageReader.swift`、`Models/MothxFileChange.swift`、`Views/StatusInline.swift`、`Views/TurnBlock.swift` | `ee42fbb` |
| BUG-0003 | 2026-08-31 | 技能 | 图片技能请求 400；激活技能后列表丢失 | 技能列表未按会话 `workDir` 维度请求；本地目录扫描出的技能被塞进 run 的 `skills` payload（服务端 SkillHub 未注册）导致 400；激活态未持久化 | 技能列表改为服务端 API 驱动（`workDir` 维度）；本地扫描技能不进入 `skills` payload；新增 `set-active` 持久化激活态 | `MothxServiceManager.swift`、`Models/MothxSkill.swift`、`Views/WorkspaceView.swift`、`Localization.swift` | `6bd97ac` |
| BUG-0004 | 2026-09-07 | 流式会话 | 流式运行中会话空白、打字机回退 | `loadMessages` 直接用服务端快照整体替换，运行中覆盖本地乐观消息与当前流式消息 | 改为 `mergedLiveMessages` 合并（按 id 刷新服务端条目、保留本地乐观消息、不剪枝当前流式消息）；活跃运行期间跳过昂贵历史重建 | `MothxServiceManager.swift`、`Views/WorkspaceView.swift` | `85189a3` |
| BUG-0005 | 2026-09-07 | 会话恢复 / 滚动 | 切换会话期间视口错位、滚动跳错位置 | 恢复期间消息/turn 变更处理器提前触发滚动，恢复未完成就定位 | 切会话先清空旧 turns 并显示加载态，待内容/折叠/prepared 就绪后再定位滚动 | `Views/WorkspaceView.swift` | `85189a3` |
| BUG-0006 | 2026-09-07 | 中文输入法 | 拼音输入被打断、组合文本错乱 | 流式刷新期间 binding→view 写回覆盖了 IME 编辑/组合文本 | `RetSubmitTextEditor` 在编辑/组合期间跳过 binding→view 写入，提交后镜像清空 | `Views/WorkspaceView.swift`（`RetSubmitTextEditor`） | `85189a3` |
| BUG-0007 | 2026-09-07 | 会话偏好持久化 | 按会话持久化 provider/model 失败 | `session_preferences` 表 `model_id` 为 `NOT NULL`，单独写 provider 时用空值失败；Restore 阶段还会写入虚假记忆 | 空串哨兵写入；Restore 写入通过 `isRestoringSession` 跳过 | `MothxServiceManager.swift` | `85189a3` |
| BUG-0008 | 2026-09-07 | Agent 工具提交 | 提交 run 报 400（未知工具/技能） | legacy profile 携带服务端不认识的工具名与技能名 | 工具改由 `/api/capabilities` 能力目录驱动，提交前按目录剪枝未知工具；未知技能转为 `/skill:` 指令而非 skills payload | `Models/MothxAgentTool.swift`、`MothxServiceManager.swift`、`Views/TeamSetupSheet.swift` | `85189a3` |
| BUG-0009 | 2026-09-07 | 文件变更 Diff | 大文件被误判为整体替换 / 显示「详细 Diff 过大」 | 用 `oldLines*newLines`（LCS 工作区大小）当阈值，衡量的是矩阵而非改动量；2,324 行文件被判为全量替换 | 改用 Myers 最短编辑脚本算法生成 unified diff，去掉 N*M 截断判断 | `Models/MothxFileChange.swift` | `88e900d` |
| BUG-0010 | 2026-09-09 | 视频预览 | 播放视频时 App 崩溃（Release/Archive 构建） | SwiftUI `VideoPlayer` 的私有 `_AVKit_SwiftUI` 桥在 macOS 26 的优化/归档构建下元数据崩溃（Debug 正常） | 改用 AppKit `AVPlayerView`（`NSViewRepresentable`）；同时补 `remoteURL` 回退与加载态 | `Views/MessageBubble.swift`（`MacVideoPlayerView`） | `aff12ac`、`9a6e516` |
| BUG-0011 | 2026-09-09 | 消息 / 文档预览 | 生成文件消息体积过大、无法预览；视频侧栏逻辑仍不稳定 | 文档类产物直接内联渲染；视频源解析（本地/远程）与加载态处理不完整 | 新增 `DocumentPreviewStrip` / `PublishArtifactDocumentCard`，产物走右侧栏 Quick Look 预览；完善 `MothxMessage` 对文档类消息的支持 | `Views/MessageBubble.swift`、`Models/MothxMessage.swift` | `9a6e516` |
| BUG-0012 | 2026-09-09 | 技能市场 / 设置 | 技能管理与市场接入的多处问题 | 技能/SkillHub 数据流与设置项耦合，刷新与状态回填不完整 | 接入 SkillHub 市场与技能管理；修正设置与技能列表刷新链路 | `Models/MothxSkill.swift`、`Views/SettingsView.swift`、`MothxServiceManager.swift` | `a72175c` |
| BUG-0013 | 2026-09-12 | 文件变更审核 / MCP 设置 | 审核块显示与 MCP 配置接入问题 | `MothxFileChange`、审核视图、TurnBlock 与新增 MCP 配置之间的数据流不一致 | 修正文件变更模型与审核视图渲染；接入 MCP 配置；补齐设置与本地化 | `Models/MothxFileChange.swift`、`Views/ChangeReviewViews.swift`、`Views/TurnBlock.swift`、`Views/SettingsView.swift`、`MothxServiceManager.swift` | `5c81eeb` |
| BUG-0014 | 2026-09-13 | 会话恢复 / 滚动 | 切换会话后会话区空白，必须手动滚屏才显示（与 BUG-0005 同模块、不同根因） | `ConversationScrollObserver.applySessionResetIfNeeded` 在新会话 `isLoading` 仍为真时就执行 `appliedScrollToBottomToken = scrollToBottomToken`，把恢复结束那一次唯一的定位请求提前消费掉；同时 `observedScrollView` 在文档重建后可能已脱离窗口层级，`refreshLayout/refreshScroll/settle` 拿不到当前滚动视图（旧代码直接用 `observedScrollView`） | ① `applySessionResetIfNeeded` 仅在 `!isLoading` 时消费 token，恢复期间把 token 留作待处理；② 新增 `resolvedScrollView()`，观察者视图不在窗口层级时从 `anchorView` 重新解析 NSScrollView；③ `settleAfterScroll` 改为 20 次并带“文档仍在增长就继续跟随底部”的判断，同时重绘 documentView 与 clipView；④ 恢复结束额外 `conversationLayoutID += 1`，强制 AppKit 对已提交的文档做一次 layout | `Views/WorkspaceView.swift` | 待提交 |
| BUG-0015 | 2026-09-13 | 流式打字机 | 长回复反复“重新加载/重新打字”，打字速度不可控（与 BUG-0004 的“打字机回退”同现象、不同根因） | `TextMessageBubble` 用 `@State displayedCharCount` 保存进度，LazyVStack 回收或回合重新 prepare 时 @State 被丢弃 → 进度归零从头再打；且每次 tick 都重建整段字符串 | 新增 `TypewriterProgressStore`（按 message id 持久化、单调不回退、上限 400 条 LRU 淘汰）让重新出现时续打；正文改为有界窗口 `maxLiveCharacters = 8_000`（只保留最新内容，从头部裁剪，窗口起点前置 “…”）；`advanceTypewriter` 自适应步长 `max(1, backlog/8)`、8ms 定时（约 120 字/秒） | `Views/TextMessageBubble.swift` | 待提交 |
| BUG-0016 | 2026-09-13 | 流式会话 / 滚动 | Run（对话）结束瞬间会话区突然整片空白，必须鼠标滚屏才重新显示（与 BUG-0005/0014 同文件、同“空白需滚屏”现象，不同根因） | `ConversationScrollObserver` 用 `NSClipView.scroll(to y: documentView.bounds.height - clipHeight)` 直接移动视口定位到底部，绕过了 SwiftUI 自己的滚动机制，SwiftUI 的可见矩形状态停留在改动前的偏移；Run 结束时正文从流式投影切换为最终 Markdown、状态行/变更卡插入，LazyVStack 不会为新偏移重新实例化行 → 整片空白，直到用户真实滚动把可见矩形刷新回内容区。`scrollToBottomNow` 还以 `documentView.bounds.height`（LazyVStack 的估算高度）为准，估算偏大时会停在没有已实例化行的位置 | 明确分工：AppKit 只负责“提交布局 + 强制重绘”，位置交还 SwiftUI。`ConversationScrollObserver` 新增 `onSettleFinished` 回调，在 settle 的 20 次布局提交完、且视口仍在底部（`distanceToBottom() <= 50`，避免把已滚走的用户拽回）时触发；`WorkspaceView` 据此调用 `ScrollViewReader.scrollTo(conversationBottomID, anchor: .bottom)` 重新声明底部——此时布局已提交，不会再与 LazyVStack 竞态，SwiftUI 的可见矩形与视口一致并重新实例化最终偏移处的行。用户中途滚走则回调不触发 | `Views/WorkspaceView.swift` | 待提交 |
| BUG-0017 | 2026-09-13 | 滚动机制整合 | 滚动机制与 SwiftUI 冲突：同一视口由 SwiftUI 与 AppKit 两个 owner 争夺，BUG-0005/0014/0016 反复补丁；配置面有 5 个 `@State` 信号量、20 帧 settle、4 秒/≤50pt 重试窗口、250ms 提交补滚与高度算术 | 直接操作 `NSClipView` 位移绕过了 SwiftUI 滚动机制，而 SwiftUI 的 `scrollTo` 在布局未提交时又与 `LazyVStack` 竞态；两个 owner 叠加出的启发式只能抵消症状，无法消除根因 | **滚动所有权只归 SwiftUI，AppKit 退化为只读上报**：新增 `ConversationScrollModel`（`atBottom` / `followBottom` / 单份合并请求）承担“是否跟随底部”；底部检测改用 `onScrollGeometryChange`（变换为 `Bool`，仅跨阈值回调）+ `onScrollPhaseChange`（macOS 15+），macOS 14 用只读 `ConversationVisibilityObserver`；定位只保留 `.task(id: request.revision)` 驱动的单条 `scrollTo(bottomAnchor)`（同帧多次请求自动合并，且首个 scroll 放在无挂起点的同步前缀以避免被取消饿死）；首帧与内容变长由 `defaultScrollAnchor(.initialOffset/.sizeChanges)` 兜住。**删除**：`ConversationScrollObserver`、settle/retry/clamp/会话重置停顶部/强制重绘、`conversationLayoutID`/`scrollToBottomRequest`/`conversationSessionToken` 三个 token、`isConversationAtBottom`、提交后 250ms 补滚。此条目取代 BUG-0014/0016 的 AppKit 防护点 | `Views/ConversationScrollModel.swift`（新）、`Views/WorkspaceView.swift`、`SCROLL_DESIGN.md`（新） | `74cf656` `616b684` `533b39e` `5f65a81` `7bd565a` |

> 说明：`88e900d` / `a72175c` / `5c81eeb` 的提交信息较笼统，根因一栏依据 diff 归纳；如后续定位到更准确的根因，直接在该行「根因」补充，不要另起新行。
>
> BUG-0014 / BUG-0015 / BUG-0016 为同一次开发中的修复。其中 BUG-0014 与 BUG-0016 描述的是**当时的 AppKit 观察者机制**（settle 20 次、`resolvedScrollView()`、`onSettleFinished` 回调等）；这些代码已由 BUG-0017 的单一 owner 设计整体删除，历史条目按“只增不改”规则保留作为当时记录，**其防护点以 BUG-0017 为准**。

---

## 2. 复发记录（被后续改动打破的已修复问题）

| 原 BUG | 复发日期 | 提交 | 现象 | 为何复发 | 处理 |
| --- | --- | --- | --- | --- | --- |
| （暂无） | | | | | |

新增规则：如果某个已修复问题再次出现，先在此表登记，再修复，最后回到第 1 节确认原条目的「回归防护点」是否要补充。

---

## 3. 回归检查清单（改代码前对照）

**通用**

- 改动是否碰到了第 1 节的「关键文件」？碰到了就要逐条确认现象不再出现。
- 提交前跑 `git diff --check` 和 Debug `xcodebuild`（见 `dev.md` 3.12）。
- 涉及 UI 的改动，按 `dev.md` 3.12「UI 验证重点」逐条自测。

**按模块**

- 会话/流式：运行中不得用服务端快照整体替换本地消息（BUG-0004）；历史轮次保持静态，只有最后一轮更新。
- 会话恢复：切换会话必须先清空 + 加载态，恢复完成后再滚动定位（BUG-0005）；恢复期间不得发滚动请求，`ConversationScrollModel.isSuppressed` 期间只允许“恢复结束”那一次显式定位（BUG-0014 → 以 BUG-0017 为准）。
- 滚动定位：滚动所有权只属 SwiftUI。不得出现 `NSClipView.scroll`/直接改 clip origin、settle 循环、`documentView.bounds.height` 重试窗口或提交后 sleep 补滚（BUG-0016/0017）；底部检测用 `onScrollGeometryChange`+`onScrollPhaseChange`（15+）或只读 `ConversationVisibilityObserver`（14）；首帧/变长靠 `defaultScrollAnchor`；`followBottom` 是“是否跟随”的唯一门，用户上滑后不得被拽回。
- 流式打字机：已显示进度必须来自 `TypewriterProgressStore`（可跨 LazyVStack 回收恢复），不得退回只靠 @State 计数（BUG-0015）；有界窗口只裁头部，不能整段清空重打（BUG-0004）。
- 输入框：编辑/IME 组合期间不得写回 binding 覆盖输入（BUG-0006）。
- 会话偏好：`session_preferences` 写 provider 时必须带非空 `model_id` 哨兵；Restore 期间跳过写入（BUG-0007）。
- Agent 提交：工具/技能必须来自服务端能力目录，未知项剪枝或转 `/skill:`（BUG-0008；另见 BUG-0003）。
- 文件变更：diff 用 Myers 算法，不得重新引入基于 `oldLines*newLines` 的截断（BUG-0009）；审核块只在有本地 `oldText/newText` 的轮次显示，大文件要显示完整 Before/After。
- 视频预览：不得改回 SwiftUI `VideoPlayer`，必须用 AppKit `AVPlayerView`（BUG-0010）。
- 技能：技能列表按 `workDir` 会话维度拉取；本地扫描技能不得进入 run 的 `skills` payload（BUG-0003）。

**硬约束（来自 dev.md，不属于 BUG 但同样不可破坏）**

- 执行边界只属于 mothx，mothxOS 不实现第二套 Agent 执行 / Run 状态机。
- 团队编排边界只属于 mothxOS。
- 接口以 `MOTHX_API.md` 为契约，schema 变化必须同步文档。
- 密钥不得进入日志、文档、源码、提交记录或普通 UI 文本。

---

## 4. 新增条目模板

```markdown
| BUG-XXXX | YYYY-MM-DD | 模块 | 一句话现象 | 根因（精确到变量/表/构建配置） | 修复要点（关键决策，写清“为什么这样改”） | 文件A、文件B | `commithash` |
```

填写要求：

- 「根因」写到具体代码位置或数据约束，不要只写「逻辑错误」。
- 「修复要点」要能解释为什么这样改，方便后人判断新改动是否与它冲突。
- 「关键文件」列全，作为下次评估回归面的入口。
- 涉及构建配置（如 Release/Archive 差异）必须写明，因为 Debug 复现不了（见 BUG-0010）。

---

## 5. 相关文档

- [dev.md](./dev.md)：两端职责边界、不可破坏约束、构建与 UI 验证清单。
- [MOTHX_API.md](./MOTHX_API.md)：客户端与服务端接口契约。
- [MOTHXOS_CODETREE.md](./MOTHXOS_CODETREE.md)：mothxOS 代码树。
