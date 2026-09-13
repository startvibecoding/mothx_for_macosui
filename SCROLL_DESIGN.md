# 对话滚动机制设计（SCROLL_DESIGN）

状态：已落地（P0 → P4.1，见第 7 节）。
适用范围：`mothxOS/Views/WorkspaceView.swift` 的会话区（不含 `TeamWorkspaceView` 的简单滚动）。

## 1. 要解决的问题

同一个视口当前有两个 owner 在抢方向：

1. **SwiftUI**：`ScrollViewReader.scrollTo` + `conversationLayoutID` / `scrollToBottomRequest` / `conversationSessionToken` / `isRestoringConversation` / `isConversationAtBottom` 五个 `@State` 当信号量。
2. **AppKit**：`ConversationScrollObserver` 直接 `NSClipView.scroll(to:)` 移动视口，并附带 20 帧 settle、4 秒/≤50pt 增长重试、越界 clamp、会话重置停顶部、强制 `needsDisplay` 重绘。

冲突根源是**直接改 clip origin 绕过了 SwiftUI 的滚动机制**：SwiftUI 的可见矩形停留在旧偏移，`LazyVStack` 不为新偏移实例化行 → 整片空白，直到真实滚屏刷新（BUG-0016）；而 SwiftUI 的 `scrollTo` 在布局未提交时又会与 `LazyVStack` 竞态（BUG-0005 的原始结论）。BUG-0005 / 0014 / 0016 是同一处反复打补丁的结果。

## 2. 设计原则

1. 滚动所有权只归 SwiftUI；AppKit 最多做**只读**可见性上报，永不移动视口。
2. “是否跟随底部”收敛为**一个** `followBottom`，替代散落的 `isLoading` / `wasAtBottomBeforeReview` / `distanceToBottom() <= 50` 判断。
3. 删掉时序启发式：20 帧 settle、250ms sleep、4 秒重试窗口、基于 `documentView.bounds.height` 的高度算术。
4. macOS 14 仍可运行：新 API 用 `#available(macOS 15.0, *)` 门控，保留一条最小只读兜底。

## 3. 目标架构

### 3.1 状态机（单一真相）

`ConversationScrollModel`（`@MainActor` + `ObservableObject`，无 AppKit 状态）：

- `atBottom: Bool`：几何派生，驱动“回到底部”按钮。
- `followBottom: Bool`：用户意图。只在**用户**（滚动相位，macOS 14 用“内容高度不变却偏离底部”的读数）改变视口时改写；**布局产生的读数不得改动它**，否则“新一轮从顶部开始”会被一次“内容还短、读数恰好在底部”悄悄取消。用户回到/要求底部（滚到底部、点底部圆钮）时置回 true。
- 新一轮对话（`startNewTurnFromTop`，reason `newTurn`）：定位到该轮**顶部**、`followBottom=false`，运行中的流式不再自动跟随；用户点底部圆钮或自己滚到底部才恢复跟随。选择历史轮次同理（reason `turnSelected`）。
- `request: ConversationScrollRequest`（`revision` + `reason` + `animated`）：合并后的定位请求。
- `isSuppressed`：恢复会话期间为 true，几何与内容增长都不得改变 `followBottom`，也不得发出请求。

定位请求的 reason：`restored`（恢复结束）、`runTerminal`（Run 终态）、`contentGrew`（跟随增长）、`userRequested`（按钮/提交）。

### 3.2 视图侧原语

```
ScrollView {
    LazyVStack { …; Color.clear.frame(height: 1).id(conversationBottomID) }
}
.conversationBottomAnchoring()            // 首帧锚定底部；15+ 在内容变长时保持锚定
.conversationScrollObservation(model)     // 15+ 几何/滚动相位；14 只读探针
.task(id: model.request.revision) { … }   // 唯一定位执行点
```

- **每个会话一个全新 ScrollView**：`.id(conversationIdentity)`，在恢复开始的那一次更新里与清空轮次同时生效。复用同一个 ScrollView 时，上一个会话深达数千点的 clip origin 会在内容被替换后存活，新会话渲染在无效偏移处 → 空白（BUG-0014 的复发，见 `BUGFIXES.md` 第 2 节）。身份重置同时让 `.initialOffset` 对新会话重新生效。
- **首帧**：`.defaultScrollAnchor(.bottom, for: .initialOffset)`（15+）/ `.defaultScrollAnchor(.bottom)`（14）——恢复/切会话天然落在底部。
- **增长跟随**：`.defaultScrollAnchor(.bottom, for: .sizeChanges)`（15+），但只在**跟随态**（`isViewingLatestTurn && followBottom`）打开——否则流式增长会把“从顶部开始阅读”的位置拽到底部。
- **探测**：`onScrollGeometryChange`（15+，变换成 `Bool` 减少刷新）+ `onScrollPhaseChange`（15+，判定用户滚动）；macOS 14 用只读 `ConversationVisibilityObserver` 上报 `(contentHeight, offsetY, viewportHeight)`，并按“内容高度未变却偏离底部 = 用户滚动”的启发式判定。
- **定位**：只保留一条 `ScrollViewReader.scrollTo(锚点, anchor:)`（锚点 = `conversationTopID` / `conversationBottomID`），由 `.task(id:)` 驱动（同帧多次请求自动合并）；`.task` 在 `isSuppressed`（恢复中）直接返回，避免早于本次恢复的旧请求给新会话定位。
- **按实际高度定稿（不是按帧数/定时器）**：`conversationContentHeight(scrollModel)` 挂在滚动内容（`LazyVStack`）上，把它每次布局后的**真实高度**报给模型。正文排版、文件预览条、修改点卡片、产物卡片、图片解码完成——只要改变了文档高度就会上报一次；模型在 `followBottom` 期间对每次高度变化重新钉底部（`.task(id:)` 合并成每次更新一次 `scrollTo`），直到某次布局高度不再变化（视为排版完成），此时的位置即为最终位置。连续变化的次数有上限（40），但一旦出现一次“高度稳定”就重新充满，因此迟到的方块仍会被跟随，而“滚动 ↔ 布局”互相触发的死循环不会无限跑。

### 3.3 删除清单

`settleAfterScroll`、`retryScrollToBottomIfNeeded`、`clampScrollOffsetIfNeeded`、`scrollToBottomNow`、`applySessionResetIfNeeded`、`needsDisplay/displayIfNeeded` 强刷、`conversationLayoutID`、`scrollToBottomRequest`、`conversationSessionToken`、`conversationWasAtBottomBeforeReview` 的滚动语义、提交后的 250ms 补滚。

## 4. 分阶段落地（每步独立可构建、可验证）

- **P0 诊断**：`[scroll]` runtime log（reason / atBottom / followBottom / contentHeight，仅元数据，无正文）。
- **P1 模型**：引入 `ConversationScrollModel` 与请求类型，8 处触发全部收敛为模型调用；执行仍交给旧观察者，行为不变。
- **P2 探测**：底部检测改用 SwiftUI 几何（15+）/只读探针（14），旧观察者不再上报底部状态。
- **P3 定位**：定位收敛为单条 `scrollTo`，删除 AppKit 位移与 settle/retry/clamp/会话重置及三个 token。
- **P4 锚定**：加 `defaultScrollAnchor`，删除旧观察者、恢复结束补滚与提交 250ms 补滚。
- **P5 收尾**：文档与 `BUGFIXES.md` 更新，最终 Debug 构建验证。

## 5. 与 BUG 登记表的对应（回归面）

- BUG-0005 / 0014（恢复空白）：`.initialOffset` 锚点让首帧天然在底部，**不存在“token 被提前消费”这一失败模式**，是从根上消除而非再打补丁。
- BUG-0016（Run 结束空白）：单一 owner 后不再可能出现“SwiftUI 可见矩形失同步”。
- BUG-0004（流式空白）：只动滚动层，不碰 `mergedLiveMessages`。
- 用户上滑不被拽回：三处分散判断收敛为 `followBottom == false` 一个门；`isSuppressed` 期间不发请求。

## 6. 验收标准与风险

验收：

1. Run 连续 3 次结束，末条内容完整可见，无需手动滚屏、无可感知跳动。
2. 连续 10 次快速切会话，首帧即显示内容且停在底部。
3. 流式中用户上滑后视口不动、按钮出现且可回到底部。
4. 长会话（>200 条消息）恢复后无空白帧。

风险与缓解：

- `defaultScrollAnchor(_:for: .sizeChanges)` 在“用户上滑阅读时内容仍在增长”的语义需实测；若不理想，退化为“仅在 `followBottom` 时显式 `scrollTo`”（当前实现同时保留该显式跟随路径）。
- `onScrollGeometryChange` 的 `contentSize` 在 `LazyVStack` 下可能含未实例化行的估算：改用哨兵 anchor 对齐，不做高度算术。
- 本机无法截图/自动化验证（终端缺少屏幕录制与辅助功能权限），需人工复现第 6.1 节四条。

## 7. 落地记录

| 阶段 | 提交 | 内容 |
| --- | --- | --- |
| 设计 | `5400d85` | 新增本文档 |
| P0 | `a5f77bb` | `[scroll]` 诊断日志（仅元数据） |
| P1 | `74cf656` | 引入 `ConversationScrollModel`，8 处触发收敛为单一 intent（执行仍走旧观察者） |
| P2 | `616b684` | 底部检测改用 `onScrollGeometryChange`（15+）/只读探针（14），删除 `isConversationAtBottom` |
| P3 | `533b39e` | 定位收敛为单条 `ScrollViewReader.scrollTo`，删除 `ConversationScrollObserver`（470 行）与三个 token |
| P4 | `5f65a81` | `defaultScrollAnchor` 锚定首帧/变长，删除提交 250ms 补滚 |
| P4.1 | `7bd565a` | 首个 `scrollTo` 放到无挂起点的同步前缀，避免流式突发把跟随滚动饿死 |
| 复发修复 | 见提交 | 切会话空白复发：`conversationIdentity` 给每个会话全新 ScrollView + 恢复结束定位（BUGFIXES 第 2 节） |
| 定稿方式 | 见提交 | 最终滚动位置改由**内容实际布局高度**驱动：`conversationContentHeight` 上报 `LazyVStack` 布局高度，高度稳定即完成；删除按帧数重复定位 |
| 新一轮置顶 | 见提交 | 新一轮对话定位到该轮顶部（`startNewTurnFromTop`）；跟随意图不再被布局读数改写，`.sizeChanges` 锚点仅在跟随态开启 |

最终形态：`WorkspaceView` 净减 ~540 行；`ConversationScrollObserver`、`settleAfterScroll`、`retryScrollToBottomIfNeeded`、`clampScrollOffsetIfNeeded`、`scrollToBottomNow`、`applySessionResetIfNeeded`、`conversationLayoutID`、`scrollToBottomRequest`、`conversationSessionToken`、`isConversationAtBottom` 全部不存在。

待人工验证（第 6.1 节）：Run 结束不空白、切会话不空白、流式上滑不被拽回、长会话恢复无空白帧。
