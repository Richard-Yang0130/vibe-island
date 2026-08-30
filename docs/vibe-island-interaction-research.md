# Vibe Island 动效、页面与交互实现研究

> 调研日期：2026-08-30
> 目标版本：Vibe Island 1.0.48 及其当前官网
> 研究范围：公开官网源码、官方演示视频、公开安装包、官方文档与更新记录、GitHub issues、创作者和用户公开分享。未使用私有源码。

## 1. 结论先行

Vibe Island 的核心并不是一个“会展开的黑色刘海”，而是一套完整的注意力调度系统：

1. 用常驻的紧凑态提供环境感知，只保留宠物、短状态、会话数或用量。
2. 把 `运行中 / 等待审批 / 等待回答 / 计划待确认 / 已完成 / 异常` 映射为不同的视觉和声音反馈。
3. 只有需要人介入的事件才抢占注意力，普通工具调用不打断用户。
4. 展开后不是单一详情页，而是会话总览、审批、问答、计划、用量等多种内容状态共用同一个容器。
5. 点击卡片后必须回到准确的窗口、标签页、分屏、tmux pane 或 IDE 会话。这个能力是产品真正的工程壁垒。

公开安装包显示它是原生 SwiftUI + AppKit 应用，使用 `LSUIElement` 常驻后台；主界面由刘海 `NSPanel` 风格窗口承载。公开符号与文案中可以确认 `NotchPanel`、`NotchWindowController`、`NotchViewModel`、`NotchDisplayState`、`NotchContentView`、`QuestionApprovalView`、`QuestionPromptView`、`JumpPlanner`、`JumpExecutor` 等独立模块。

## 2. 证据等级

| 等级 | 含义 | 本报告中的例子 |
| --- | --- | --- |
| A | 官方当前实现直接可见 | 官网 DOM、CSS、JS 状态机；v1.0.48 DMG 的 Info.plist、依赖、资源和公开符号 |
| B | 官方产品行为说明 | 官网功能页、隐私说明、changelog、官方 YouTube 演示 |
| C | 官方 issue 中确认的行为与缺陷 | hover 卡顿、问答向导、审批同步、精准跳转、多屏问题 |
| D | 用户或创作者公开体验 | 小红书、B 站、官网引用的社交媒体评价 |

以下尺寸和曲线来自官网演示代码，适合作为高保真复刻基线；它们不等于原生 App 内部常量被公开。

## 3. 页面与状态结构

### 3.1 紧凑态 Compact

官网当前基线为 `240 × 36 px`，下侧圆角约 `10–14 px`。物理刘海两侧各用约 `13 px` 的凹肩连接，视觉上像从硬件刘海长出来，而不是悬浮在菜单栏下方。

内容只保留：

- 像素宠物或状态图标
- 当前会话的极短标题/动作，如 `Working…`
- 会话数量
- 可选的用量窗口或提醒点

宠物不是装饰贴图。它同时编码工作状态，官网使用的语义色包括：

- 绿色：空闲、完成、可继续
- 蓝色：运行、工具调用
- 橙色：审批、需要注意
- 青色：问题等待回答
- 紫色：探索或特殊 Agent 状态
- 灰色：结束、不可用

### 3.2 会话总览 Overview

官网目标尺寸约 `380 × 175 px`。布局是固定的信息层级：

1. 顶部用量条：Provider 图标、5h/7d 窗口、百分比和重置倒计时。
2. 当前主会话：宠物、任务标题、Agent 标签、终端标签、持续时间、第一条用户目标、当前动作。
3. 其他会话：压缩成一行，只显示状态点、标题、Agent、宿主应用和持续时间。

主会话不是永远第一项，而是当前最需要关注或最近活跃的会话。完成但未查看的会话会保持可见，并显示 `Done — click to jump`。

### 3.3 审批 Approval

官网基线尺寸约 `380 × 220 px`，橙色作为事件强调色。页面结构为：

- `Permission Request` 标题和状态点
- 工具名，例如 Edit/Bash/Write
- 路径、命令或目标资源
- 对 Edit/Write 的内嵌 diff 预览
- 操作按钮和键盘提示

旧版官方视频展示过 `Deny / Allow Once / Allow All / Bypass` 四个动作；当前官网简化演示为 `Deny / Allow`。v1.0.48 的公开本地化资源仍包含 Allow Once、Always Allow、Bypass、Auto Mode 等文案，说明真实 App 会根据 Agent、权限模式和设置动态生成动作集合。

多条审批不是并排堆叠，而是进入请求队列，按会话和请求 ID 逐一处理。

### 3.4 问答 Ask User Question

官网基线尺寸约 `340 × 165 px`，使用青色强调：

- Agent 名称和“asks”标题
- 问题正文
- 一组可点击选项
- `⌘1 / ⌘2 / ⌘3` 快捷键提示

当前产品还支持：

- 自定义多行回答
- 多选题
- 多问题分页向导
- 上一题/下一题/最终提交
- 收起后保留未提交草稿
- 关闭自动展开，仅在紧凑态显示等待提示

GitHub issue #105 记录了从“所有问题平铺”升级为分页 wizard 的过程，v1.0.34 起已采用逐题导航。

### 3.5 计划评审 Plan Review

计划评审是独立内容态，不应复用普通审批的两行摘要。真实能力包括：

- 完整 Markdown 渲染
- 计划滚动阅读
- 批准、手动审批、Bypass 或 Auto Mode
- 文本反馈输入
- Codex 原生计划只读预览后跳回 Codex 继续操作

必须用 session/request identity 绑定计划，不能只按“当前最新计划”展示。官方更新记录曾修复“另一个会话的计划误显示”问题。

### 3.6 完成与精准跳转 Jump

完成态回到会话列表结构，但主会话变成绿色高亮，状态文案为 `Done — click to jump`。官方视频显示点击后目标窗口会被激活，并短暂出现绿色描边，给用户明确的空间定位反馈。

精准跳转不是一个动作，而是 resolver 链：

- Apple Terminal：Apple Events + `termSessionId`/TTY + Space 切换
- iTerm2/Ghostty/Warp/WezTerm/Kitty/Zellij/tmux：各自的 tab、pane、socket 或脚本能力
- VS Code/Cursor/Windsurf：轻量 IDE 扩展保存窗口/会话身份
- 普通应用：Accessibility 或应用激活降级
- SSH Remote：跳回本地承载 SSH 连接的终端 tab/pane

v1.0.48 还会在跳转后验证正确窗口是否真的获得焦点，而不是把“activate 调用成功”当成完成。

### 3.7 用量与统计 Usage

用量不是单独菜单，而是会话控制面的顶部信息层：

- 多 Provider 轮换或锁定
- 5 小时、7 天、月度等不同窗口
- 百分比、重置倒计时、警戒色
- 多账号切换
- Codex 额外 credits 与 reset cards
- 点击进入按天、月、模型拆分的 token/cost dashboard

当前 changelog 明确提到用量头部采用一致布局，专门处理物理刘海两侧空间不足和内容裁切。

### 3.8 设置与 onboarding

公开资源确认主要设置面包括：

- General
- Display / Notch
- Notifications / Mobile notifications
- Sound / Quiet Hours / Quiet Scenes
- Shortcuts
- Usage
- Permissions
- SSH Remote
- Labs

Display 中可配置 hover 展开、hover 延迟、鼠标离开收起、完成时自动展开或仅显示 Glance 点、问题是否自动展开、外部点击关闭、面板文字大小、刘海宽高微调、模型/推理强度/项目名/子 Agent/任务清单是否显示。

onboarding 的公开文案与视频说明其顺序大致为：欢迎与价值说明 → 检测本机 Agent/终端 → 自动安装 hooks/IDE 扩展 → 权限引导 → 交互演示 → trial/license → 完成。用户评价反复提到 onboarding 流畅，这是需要单独复刻的产品环节。

## 4. 动效参数与状态机

### 4.1 容器形变

官网当前演示的容器参数：

| 状态 | 目标尺寸 | 下侧圆角 |
| --- | --- | --- |
| compact | 240 × 36 | 10 |
| overview | 380 × 175 | 14 |
| approval | 380 × 220 | 14 |
| ask | 340 × 165 | 14 |
| approved | 260 × 40 | 10 |
| jump | 380 × 175 | 14 |

宽高使用 `0.5s cubic-bezier(0.175, 0.885, 0.32, 1.1)`，带轻微 overshoot；圆角和阴影使用约 `0.4s ease-out`。这比统一的 SwiftUI `.spring()` 更容易稳定调出“先长出容器，再安放内容”的感觉。

### 4.2 内容切换

各内容层绝对叠放在同一容器中：

- 离场：opacity 0、blur 6、scale 0.96
- 入场：opacity 1、blur 0、scale 1
- opacity 约 0.25s
- blur 约 0.30s
- scale 约 0.35s，使用同一 spring curve
- 新层延迟约 60ms 入场

因此视觉上不会看到页面推挤或列表重排。容器几何变化与内容交叉淡化是两条独立动画通道。

### 4.3 注意力策略

推荐还原成两层状态机：

```text
SessionState
idle → running → needsApproval / needsAnswer / needsPlan → completed / failed

DisplayState
hidden / compact → peek → overview / approval / question / plan / usage
                         ↘ acknowledgement → compact
```

关键规则：

- 普通运行状态不主动展开。
- 审批、问题、计划可以自动展开并播放独立声音。
- 完成可以选择完整展开或只显示绿色 Glance 点。
- 鼠标 hover 展开有可配置延迟，公开设置上限至少 0.8 秒。
- 鼠标离开可自动收起；ESC 可立即收起。
- 外部点击只立即关闭完成/警告等轻量 reveal，不能误清除未处理审批。
- Focus Mode、锁屏、录屏/共享屏幕可进入 Quiet Scene，只保留微弱状态点。
- 多条请求进入队列；新事件不能让已经处理的旧状态“复活”。

### 4.4 官网演示时间轴

官网自动演示的停留时间为：Overview 5.5s、Approval 5.6s、Ask 4.3s、Jump 12.8s。这是营销演示节奏，不应直接用作 App 的自动关闭时间。真实 App 的 dwell time 可配置，并允许用户关闭自动展开。

## 5. 公开证据支持的技术架构

### 5.1 窗口层

- `LSUIElement = true`，不占 Dock。
- AppKit panel 负责跨 Space、菜单栏层级、点击穿透、激活和辅助功能。
- SwiftUI 负责内容树、状态绑定和视觉动画。
- 物理刘海通过屏幕顶部可用区域计算锚点；无刘海屏幕使用模拟岛，但必须避让菜单栏图标。
- 面板应使用固定的透明 stage frame，内部只动画岛形和内容。不要在每一帧反复改变 NSPanel 尺寸。

### 5.2 事件层

官方隐私说明表明：Agent hooks 通过本地 Unix socket 发送状态；应用也会只读本地 JSONL session 文件，用于会话标题和上下文；不上传代码、prompt 或回复。

需要把每种 Agent 的事件归一化为统一模型，至少包含：

```text
sessionId, provider, agent, hostApp, project, title,
status, currentTool, tasks, model, reasoningEffort,
terminal/window/tab/pane identity,
approval/question/plan payload,
parentSessionId, timestamps
```

### 5.3 审批与问答

请求必须以稳定 request ID 建模，并支持双向同步：

1. hook/adapter 创建 pending request。
2. Notch 渲染请求并允许提交。
3. response transport 把结果发回 Agent。
4. 无论用户在 Notch 还是原终端回答，后续事件都应清除同一个 pending request。
5. 已处理请求要幂等，不能被延迟事件重新激活。

issue #70 证明“只发送，不观察另一侧状态”会导致终端已经批准、岛上仍显示 pending。

### 5.4 精准跳转

每个 session 在创建时就要记录可寻址的 host identity，不能等点击时再猜。建议 resolver 接口输出明确步骤：

```text
resolve session identity
→ switch owning Space
→ activate app
→ select window
→ select tab/split/pane/thread
→ verify focus
→ report precise/fallback/failure
```

issue #186 说明只保存 bundle identifier 最多只能激活应用，无法承诺“精准跳转”。

### 5.5 声音

公开安装包依赖 AVFAudio，资源和 changelog 同时说明内置 8-bit 实时合成、按事件独立声音、自定义 sound pack、音量、静音时段、Focus/录屏静音。声音应由事件语义触发，而不是由某个 View 出现触发，否则 stale UI 会重复播放。

## 6. 最容易复刻失败的地方

1. **动画卡顿**：issue #44 指向高刷屏 frame pacing。官方后续通过减少布局计算、优化大列表、缩小 hover hit-test 和降低主线程工作量缓解。
2. **hover 抖动**：panel 尺寸变化会改变鼠标命中区域，导致刚展开就失去 hover。必须使用固定 stage、grace area 和 cooldown。
3. **幽灵会话**：桌面 App helper、零轮次会话、子 Agent、回滚和重连都会制造重复 identity。
4. **状态闪烁**：工具失败不等于整轮失败；子 Agent 完成不等于父会话完成；compaction 不等于任务结束。
5. **审批不同步**：Notch 和原终端必须共用请求生命周期。
6. **跳转降级无提示**：Accessibility/Automation 缺失时不能静默宣称跳转成功。
7. **多显示器**：无刘海外接屏会覆盖菜单栏图标；Follow Focus、全屏隐藏和 Space 切换必须独立处理。
8. **内容裁切**：用量、模型、推理强度、项目名和多账号信息不能同时无上限展示，需要明确压缩优先级。

## 7. 对 CodexBar 复刻的直接要求

要做到“像 Vibe Island”，验收不能只看静态截图，至少要满足：

- 同一个容器完成 compact、overview、approval、question、plan、acknowledgement、usage 的状态切换。
- 形变和内容转场分离；高刷屏下无明显掉帧和 hover 回弹。
- 事件优先级正确，普通运行不打扰，审批/问题不会被自动收起或误清除。
- 会话卡能表达 Agent、宿主、项目、当前动作、模型、推理强度、子 Agent 与任务清单。
- 审批、问答、计划都能双向同步，而不是只做静态卡片。
- 点击卡片能验证精准跳转结果；失败时展示原因和降级状态。
- 支持 ESC、外部点击、hover 延迟、完成 Glance、Quiet Scene、声音和快捷键偏好。
- onboarding 能自动检测并解释 hooks、Accessibility、Automation、IDE 扩展等权限。

## 8. 主要公开来源

- 官网与实时演示：[vibeisland.app](https://vibeisland.app/)
- 官方功能页：[Session Monitoring](https://vibeisland.app/ai-coding-session-tracker/)、[Multi-Agent](https://vibeisland.app/multi-agent/)、[Precise Jump](https://vibeisland.app/precise-jump/)、[Usage](https://vibeisland.app/usage/)
- 官方交互说明：[Approve permissions from the notch](https://vibeisland.app/guides/approve-ai-agent-permissions-from-notch/)
- 官方更新记录：[Changelog](https://vibeisland.app/changelog/)
- 官方隐私说明：[Privacy Policy](https://vibeisland.app/privacy/)
- 官方演示视频：[Vibe Island demo](https://www.youtube.com/watch?v=_nh_OE5aSwI)
- 官方社区仓库：[vibeislandapp/vibe-island](https://github.com/vibeislandapp/vibe-island)
- 关键 issues：[hover expansion #44](https://github.com/vibeislandapp/vibe-island/issues/44)、[multi-question wizard #105](https://github.com/vibeislandapp/vibe-island/issues/105)、[approval sync #70](https://github.com/vibeislandapp/vibe-island/issues/70)、[precise jump #186](https://github.com/vibeislandapp/vibe-island/issues/186)、[menu bar overlap #193](https://github.com/vibeislandapp/vibe-island/issues/193)
