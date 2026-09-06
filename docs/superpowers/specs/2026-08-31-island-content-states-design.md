# Island 内容态重构设计（demo 对齐 · 接真实数据）

> 日期：2026-08-31
> 前置：`2026-08-30-vibe-island-shell-design.md`（外壳）、`2026-08-31-island-status-indicators-design.md`（状态灯）
> 参考实现：`island-demo.html`（Claude Code × Codex 状态岛原型）
> 分支：`feature/vibe-island-shell`

## 1. 这次要解决的问题

外壳阶段已经交付：刘海轮廓、compact/expanded 形变、内容先淡出后形变的双通道动画、hover/ESC 编排、固定舞台窗口、启动夹具。

但外壳里装的还是**假数据**。`NotchBarState.shellPresentation` 恒定传 `fixture: .reference`，而同一个 state 上 `card`、`taskAggregates`、`attention`、`activeSession` 四份**真实数据**就挂在旁边没人读。同时 demo 里承载产品价值的东西一个都还没有：像素精灵、状态语义色、会话卡、审批面、问答面、完成跳转、确认窄条。

这一阶段做两件事：

1. **重构**：把外壳从「一个 expanded 布局」升级成「一个容器 + 多个内容态」，删掉 `NotchIslandView.swift` 里已经没人调用的旧视觉树。
2. **接真数据**：fixture 退回 Debug 夹具画廊，生产路径全部读 `UsageStore` / `AgentTaskStatusStore` 的真实状态。

## 2. 起点盘点

### 2.1 可以原样复用

| 资产 | 位置 | 说明 |
| --- | --- | --- |
| 轮廓 Shape | `IslandShellView.IslandShellShape` | 凹肩 + 下侧圆角，animatable，直接沿用 |
| 动效档案 | `IslandShellMotion` | 0.50s timingCurve 容器 / 0.40s 圆角 / 0.25-0.30-0.35s 内容三通道 + 60ms 延迟，与 demo 完全一致 |
| 舞台几何 | `NotchGeometry.layout` | 物理刘海探测、模拟锚点、固定 stage frame、边缘 clamp |
| hover 编排 | `NotchBarController` + `IslandShellInteractionPolicy` | 0.20s dwell、16pt grace、0.25s cooldown、指针看门狗 |
| 状态灯 | `NotchCollapsedPresentation` / `NotchLightPresentation` | 已接真实 `AgentTaskStatus`，是唯一一处已经接了真数据的地方 |
| 像素字体 | `IslandShellFont`（Departure Mono, OFL） | 等宽像素字体，用于精灵旁的短状态与用量列对齐 |

### 2.2 必须删除（死代码）

`NotchIslandView.swift` 的 `body` 现在只渲染 `IslandShellView`，以下符号全部不可达，本次一并移除：

`NotchIslandView.island` / `.background` / `.shape`、`NotchIslandShape`、`NotchBandView`、`NotchProviderLightsView`、`NotchDetailView`、`NotchHeroView`、`NotchPlaceholderBadge`、`NotchGaugeRing`、`NotchMetricRow`、`NotchMeter`、`NotchFooterView`、`NotchProviderChip`、`NotchIconButton`。

外壳 spec 当初写「验收前不删除旧实现」，外壳已经验收通过，现在是约定的收尾时机。`NotchDetailPlan` 保留 —— 它仍是用量条读取 `UsageMenuCardView.Model` 的解析层。

### 2.3 与 demo 的差距

demo 有、Swift 侧完全没有的：8×8 像素精灵（身份槽 + 状态槽）、状态语义色板、用量条阈值着色、会话卡（chips + 状态点 + prompt 行）、审批面（工具头 + diff + 四档风险按钮）、问答面（选项 + ⌘1..3）、完成态、确认窄条、按场景的尺寸表与光晕。

## 3. 审批：协议支持，是本仓库自己关掉的

> 修订记录：本节初稿断言「审批做不成真的」，那是错的。协议层面 Codex 和 Claude Code **都支持**由 hook 代替用户做出授权决策。下面是核实后的结论。

### 3.1 两边协议都支持

两个 agent 都有 `PermissionRequest` hook：在需要授权时**同步**触发，stdin 带 `tool_name` 和 `tool_input`，stdout 返回决策对象。

```json
{
  "hookSpecificOutput": {
    "hookEventName": "PermissionRequest",
    "decision": { "behavior": "allow" }
  }
}
```

`behavior` 取 `allow` / `deny`，`deny` 可带 `message`。命令类 hook 的默认超时都是 600 秒，可按 handler 配置 —— 足够等用户在岛上点一下。

### 3.2 三个阻塞点全在我们自己代码里

| # | 阻塞点 | 位置 | 性质 |
| --- | --- | --- | --- |
| 1 | hook 注册成发完即忘 | `AgentTaskHookDocument.install` 写死 `"async": true, "timeout": 1` | 配置选择 |
| 2 | 负载被丢弃 | `AgentTaskEventNormalizer` 只取 5 个字段，`tool_name`/`tool_input` 全扔 | 解析选择 |
| 3 | 传输单向 | `CLIAgentEventCommand` 发完就返回、不读回复、不写 stdout，硬编码 250ms 上限；socket server 只有 `receive` | 架构选择 |

第 1 条是决定性的：两边文档都明确说后台 hook 不能 gate 操作 —— Codex 写「background hooks can't block, approve, rewrite, or otherwise control the operation；PermissionRequest 必须同步运行」，Claude 写 `async:true` 时 `timeout` 根本不生效。现有配置恰好是让审批不可能的那一种。

三条都可逆，不需要新协议，也不需要改 agent。

### 3.3 四档按钮不是设计师编的

demo 的 `Deny / Allow Once / Allow All / Bypass` 在 Claude Code 里能 1:1 落到真实词汇上：

| 按钮 | 映射 |
| --- | --- |
| Deny | `decision.behavior:"deny"` + `message` |
| Allow Once | `decision.behavior:"allow"` |
| Allow All | `allow` + `updatedPermissions:[addRules…]`。文档原话：把收到的 `permission_suggestions` 原样回传，「等价于用户在对话框里选了 always allow」 |
| Bypass | `updatedPermissions:[{type:"setMode",mode:"bypassPermissions"}]` |

Claude 的 `PermissionRequest` 输入还带 `permission_suggestions` 数组，就是对话框里那几个「始终允许」选项 —— 岛上的按钮可以直接由它生成，而不是我们猜。

### 3.4 但两边能力不对等，别按 parity 设计

**Codex 今天只能做两档。** `updatedInput` / `updatedPermissions` / `interrupt` 在 Codex 侧是保留字段且 **fail closed**，返回了会让 hook 判定失败。所以 Codex 上只有 Deny 和 Allow Once 是真的，Allow All / Bypass 无法表达。

其余必须设计进去的差异与风险：

- **Codex hook 需要信任。** 非托管 hook 要经 `/hooks` 审阅并信任才生效，信任绑定 hash。装完不提示用户去信任，等于装了个哑弹。
- **Codex 触发过早。** `PermissionRequest` 也会为自动审核的请求触发（openai/codex#28833 正在请求 `approvals_reviewer` 字段），我们可能弹出用户本来根本看不到的授权。
- **超时语义不同。** Claude 侧 hook 超时 = 不做决策，回落正常授权流程（安全）。但在**无法弹窗的非交互会话里，没有任何 hook 给出决策时 Claude 会直接拒绝** —— 岛挂掉可能让后台 subagent 全线自动拒绝。
- **allow 不是万能的。** Claude 侧 deny/ask 规则仍会照常评估，hook 返回 allow 也压不过匹配到的 deny 规则。
- **同步 hook 会阻塞用户的真实 agent。** 这是最需要谨慎的一条：一旦改成同步，CodexBar 里的任何 bug 都会卡住用户 Claude Code / Codex 的每一次工具调用。必须自带超时、fail-open 和一键关闭。

### 3.5 本阶段的取法

本阶段（内容态重构）**不接**审批回传，审批态先渲染真实阻塞状态 + 跳回终端。上面这些是下一阶段的输入，按 §3.2 三条依次拆除，Claude 先行、Codex 跟进两档。

## 4. 目标 / 非目标

### 目标

- 单一容器承载 `dormant / compact / overview / approval / ask / done / ack` 七个态，切换走已有的双通道动画。
- 8×8 像素精灵系统：左槽编码 agent 身份，右槽编码工作状态，工作态 3 帧循环，整数像素步进。
- 状态语义色板 + 用量阈值着色，全部来自真实数据。
- 会话卡读真实 `AgentTaskSessionState`；用量条读真实 `UsageMenuCardView.Model`。
- 完成态点击卡片 → 真实跳回终端。
- 需要用户介入的状态（needsApproval / failed）自动展开；普通 running 不打扰。
- fixture 保留为 Debug-only 夹具画廊，供视觉回归定格。

### 非目标

- 审批/问答的真实回传（见 §3）。
- 8-bit 音效（demo 有，但声音应由事件语义触发，需要先有稳定的事件生命周期；单独排期）。
- 计划评审 Plan Review、多问题分页向导、SSH Remote、Quiet Scenes。
- Settings 面板改造。

## 5. 架构

### 5.1 场景状态机

`IslandShellPhase` 只描述几何（dormant/compact/expanded），无法表达「同样是展开，但里面是审批还是问答」。引入 `IslandScene` 作为唯一真相，几何由它派生：

```text
IslandScene
  dormant | compact | overview | approval | ask | done | ack
```

尺寸表（沿用 research §4.1 官网基线，与外壳 spec 已定的 compact/expanded 一致）：

| 场景 | 内容宽 | 高 | 下侧圆角 | 光晕 |
| --- | ---: | ---: | ---: | --- |
| dormant | anchor | anchor | 0 | 无 |
| compact | 240 | 36 | 10 | 无 |
| overview | 380 | 175 | 14 | 白 4% |
| approval | 380 | 175 | 14 | 橙 20% |
| ask | 340 | 165 | 14 | 青 20% |
| done | 380 | 175 | 14 | 绿 16% |
| ack | 260 | 40 | 10 | 无 |

光晕用外发光而非描边 —— 岛是纯黑实体，描边会破坏「从屏幕里长出来」的观感。这条是 demo 注释里明确写死的，照搬。

两条与官网基线的偏离，都是被数据逼出来的，不是审美选择：

- **approval 取 175 而非 220。** 官网那 220pt 是留给内嵌 diff 预览的高度。我们的 hook 负载拿不到 `tool_input`（§3），渲染不出 diff，照抄 220 只会在按钮下方留一块纯黑空洞。按实际内容定高。
- **ask 场景当前无法被真实数据触发。** `AgentTaskEventNormalizer.hookKinds` 里没有任何问答类事件映射，`AgentTaskStatus` 也没有「等待回答」这个状态。场景、视图和夹具都已就位，但在问答事件接入前，它只能通过 `--island-fixture-scene ask` 看到。表头因此用独立文案 `island_waiting_answer`，不复用审批状态名。

状态迁移：

```text
compact ──hover/click──> overview ──ESC/leave──> compact
compact ──needsApproval──> approval ──跳转/忽略──> ack ──2s──> compact
compact ──completed────> done ──点卡片──> 跳转 + ack ──> compact
```

`ack` 是自动回落态：2 秒后回 compact，不打断用户当前在做的事。

### 5.2 像素精灵

`IslandSprite`：8×8 点阵，字符串位图，`Canvas` 整数像素步进渲染（`px = 2`，即 16×16 pt）。

- **身份槽**：`claude` / `codex`，用品牌色（Claude `#D97757`，Codex `#10A37F`）。
- **状态槽**：`work0/1/2`（3 帧等高柱状图，420ms 轮换）、`alert`、`ask`、`done`、`idle`，用状态语义色。

两个坑必须避开，都是 demo 注释里踩过的：

1. 颜色必须是字面色值，不能是语义引用 —— demo 里传 CSS 变量给 canvas 会静默变黑，黑底画黑等于精灵消失。Swift 侧对应的是必须给 `Color` 具体分量，不要依赖会在深色模式下变化的 semantic color。
2. 工作态是**换帧**，不是位移动画。整数像素步进，绝不做亚像素位移，否则像素风立刻散架。

### 5.3 状态语义色

```text
idle     #22C55E   空闲 / 完成
work     #3B82F6   运行中
alert    #F97316   等待审批
question #06B6D4   等待回答
ended    #737373   结束 / 不可用
danger   #DC2626   失败 / 放弃管控
```

用量健康度独立于状态色：`ok #22C55E` / `warn #F97316` / `crit #EF4444`，阈值沿用 `NotchPalette.warningThreshold 0.55` 与 `criticalThreshold 0.82`。

`AgentTaskStatus` → 状态槽映射：

| AgentTaskStatus | 精灵 | 色 |
| --- | --- | --- |
| `running` | work0/1/2 | work |
| `needsApproval` | alert | alert |
| `completed` | done | idle |
| `failed` | alert | danger |
| `interrupted` | idle | ended |
| `disconnected` | idle | ended |
| `idle` | idle | idle |

### 5.4 真实数据映射

| 岛上的东西 | 数据来源 | 缺失时 |
| --- | --- | --- |
| 用量条百分比 / 重置倒计时 / 阈值色 | `NotchBarState.card` → `UsageMenuCardView.Model.metrics`，经 `NotchPalette.usedFraction` | 整条隐藏 |
| 会话卡列表 | `taskAggregates[provider].sessions` | 空态文案 |
| 卡片标题 | `session.taskTitle ?? projectPath.lastPathComponent` | provider 名 |
| 卡片时长 | `now - session.updatedAt`，压成 `27m` / `1h04` | 省略 |
| agent chip | `session.provider` → `Claude` / `Codex` | — |
| 终端 chip | `AgentTaskFocusResolver.resolve` 命中的 `AgentSession` | 省略该 chip |
| 折叠态标签与计数 | 优先级最高的 session 状态 + 会话总数 | `idle` |
| 跳转 | `openDisplayedAgentTask()` | 灰掉卡片 |

`hidePersonalInfo` 为真时，标题降级为状态名，路径与 prompt 行不渲染 —— 沿用 `NotchTaskDetailPlan` 已有的隐私策略。

### 5.5 组件边界

| 文件 | 职责 | 禁止 |
| --- | --- | --- |
| `IslandScene.swift` | 场景枚举 + 尺寸/圆角/光晕表 | 不含视图、不读 store |
| `IslandSprite.swift` | 8×8 位图表 + Canvas 渲染 + 帧循环 | 不含业务语义 |
| `IslandPalette.swift` | 状态语义色 + 用量阈值色 | 不含视图 |
| `IslandContentModel.swift` | 纯值类型：`IslandUsageStrip`、`IslandSessionCard`、`IslandApprovalDetail`、`IslandAskDetail`；从真实 store 快照构造 | 不含视图、不含 AppKit |
| `IslandSceneViews.swift` | 各内容层视图 | 不直接访问 SettingsStore / Provider / store |
| `IslandShellView.swift` | 容器：背景、裁剪、光晕、层切换、手势 | 不拼装业务内容 |
| `NotchBarController` | 场景决策、自动展开策略、ack 回落计时 | 不拼装视图 |

单元测试全部围绕 `IslandScene` 与 `IslandContentModel` 这两个纯值层写 —— 它们不碰 AppKit，可以在 CI 上跑。

## 6. 分步实施

每步独立可编译、可提交：

1. **收尾外壳**：删除 §2.2 列出的死代码，`NotchIslandView.swift` 只保留 `NotchIslandView` + 指示灯相关类型。
2. **纯值层**：`IslandScene`（尺寸表 + 迁移规则）、`IslandPalette`、`IslandSprite` 位图表，配套测试。
3. **内容模型**：`IslandContentModel` 从 `NotchBarContentSnapshot` 构造，覆盖时长压缩、标题降级、隐私、空态，配套测试。
4. **视图层**：overview / approval / ask / done / ack 五个内容层，接 `IslandShellView` 的层切换。
5. **控制器**：场景决策（attention 驱动自动展开）、ack 2 秒回落、跳转接线、hover 冷却与场景的交互。
6. **夹具**：`--island-fixture-scene <name>` 覆盖全部七态，Debug-only。

## 7. 验收

- `swift build` 与 `swift test --filter Island` 通过，`make check` 通过。
- 七个场景各自可用启动夹具定格截图。
- 尺寸与 §5.1 表格误差 ≤ 2pt。
- Reduce Motion 下 0.14s 完成、无 blur、无 overshoot。
- 折叠态在没有任何 agent 事件时不发光、不展开、不抢注意力。
- 用量条在无真实用量数据时整条隐藏，不显示占位假数字。
- 审批态不出现任何点了没有效果的按钮（§3 约束）。
