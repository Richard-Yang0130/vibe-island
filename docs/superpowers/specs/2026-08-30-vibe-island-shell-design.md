# Vibe Island 外壳高保真复刻设计

## 目标

第一阶段只复刻 Vibe Island 的外壳和动效，不接入额度、会话、审批、问答、计划、声音或精准跳转等业务功能。

这一阶段结束时，CodexBar 应拥有与 Vibe Island 一致的刘海轮廓、Compact/Expanded 两种基础形态、展开收起动效、hover/click/ESC 交互和可重复截图的夹具内容。所有业务区域只使用固定演示数据。外壳验收通过后，再以同一容器逐项接入真实功能。

## 已确认的产品边界

- 废弃当前 Notch 的视觉产品层，不继续修补现有卡片样式。
- 保留 CodexBarCore、Provider、账户、额度解析、设置存储和刷新管线。
- 第一阶段不读取真实账户或 Keychain，不触发真实 Agent hooks。
- 保留 CodexBar 品牌；轮廓、布局、像素语言和动画按 Vibe Island 复刻。
- 第一阶段只交付外壳。真实额度是第二阶段第一个接入的功能。

## 方案选择

采用“固定舞台 + 内部形变 + 夹具画廊”方案。

AppKit 只创建一个固定尺寸、完全透明的顶部舞台窗口。舞台不随动画逐帧改变 frame；SwiftUI 在舞台内部改变岛的宽、高、圆角、阴影和内容层。这能避免窗口 resize、hover hit-test 和 SwiftUI layout 同时发生造成的抖动，也是公开 issue 中暴露的主要风险。

另两个方案不采用：

- 继续让 NSPanel 随内容自适应尺寸：代码少，但容易产生 hover 回弹、自缩放崩溃和高刷屏 frame pacing 问题。
- 新建独立 App 重写：隔离彻底，但会丢失现有额度和 Provider 基础能力，不符合后续保留额度的要求。

## 外壳状态

第一阶段只有三个显示状态：

```text
dormant → compact → expanded
   ↑          ↘       ↓
   └──────── collapse ┘
```

- `dormant`：没有可见内容，只保留物理刘海或模拟刘海的透明命中区域。
- `compact`：240 × 36 的紧凑岛，显示固定像素宠物、固定短标题和固定会话数。
- `expanded`：380 × 175 的总览外壳，显示固定的用量占位行、一个主会话占位卡和两个次会话占位行。

第一阶段不建立 approval/question/plan 等业务状态。它们在功能阶段作为新内容层加入，不再改动外壳几何系统。

## 几何规格

### 物理刘海屏

- 使用 `NSScreen.auxiliaryTopLeftArea` 与 `auxiliaryTopRightArea` 计算物理刘海矩形。
- 岛的顶边与屏幕顶边对齐，视觉上从硬件刘海向下生长。
- 两侧各绘制 13 pt 凹肩，连接物理刘海与岛身。
- 所有可见像素限制在岛形内部，舞台其余区域透明并点击穿透。

### 无刘海或外接屏

- 顶部居中生成 84 × 20 的模拟锚点。
- 模拟岛与屏幕顶边保留 6 pt 间距。
- 展开体仍使用相同凹肩和下侧圆角。
- 第一阶段只做居中模式；跟随焦点屏幕与菜单栏避让属于后续兼容性功能。

### 目标尺寸

| 状态 | 内容宽度 | 总高度 | 下侧圆角 | 凹肩 |
| --- | ---: | ---: | ---: | ---: |
| compact | 240 | 36 | 10 | 13 |
| expanded | 380 | 175 | 14 | 13 |

舞台窗口固定为 494 × 520。Expanded 的 406 pt 可见总宽度之外左右各预留 44 pt 阴影空间，垂直空间足够容纳后续审批和计划视图。

## 轮廓与材质

- 主体使用纯黑 `#000000`，保证与物理刘海融合。
- 展开态只增加极轻的底部轮廓光，不使用当前实现中的大面积彩色径向渐变。
- Compact 阴影：`0 2 8 rgba(0,0,0,0.60)` 与 `0 8 24 rgba(0,0,0,0.30)`。
- Expanded 额外增加 `0 0 15 rgba(255,255,255,0.04)`。
- 轮廓裁剪必须覆盖内容、背景和 hover 命中区，凹肩外的透明区域不得阻挡菜单栏点击。
- 内容字体使用 SF Pro/system font；像素宠物和短状态采用 Departure Mono 风格。字体资源加入前必须使用可再分发的公开授权版本并保留许可证。

## 动效规格

### 容器形变

- 宽度和高度：0.50 秒，`cubic-bezier(0.175, 0.885, 0.32, 1.1)`。
- 下侧圆角和阴影：0.40 秒，ease-out。
- 展开允许轻微 overshoot，收起不得反复回弹。
- Reduce Motion 开启时统一降级为 0.14 秒 ease-out，不使用 blur 或 overshoot。

SwiftUI 使用显式 `Animation.timingCurve` 表达该曲线，不能用当前通用 spring 近似替代。

### 内容层切换

- Compact 和 Expanded 内容绝对叠放，不参与彼此的 layout 推挤。
- 离场：opacity 1 → 0、blur 0 → 6、scale 1 → 0.96。
- 入场：opacity 0 → 1、blur 6 → 0、scale 0.96 → 1。
- opacity 0.25 秒，blur 0.30 秒，scale 0.35 秒。
- 新内容在容器开始形变 60 毫秒后入场。

### hover 稳定性

- hover 进入延迟固定为 0.20 秒。
- 岛形外增加 16 pt grace zone，只参与离场判断，不可见也不拦截其他应用点击。
- 收起后设置 0.25 秒 hover cooldown，避免鼠标仍处于旧坐标时立刻重新展开。
- mouse leave 触发收起；点击 Compact 立即展开；点击 Expanded 顶部区域或按 ESC 收起。

## 夹具内容

第一阶段使用固定 fixture，不调用真实服务：

### Compact

- 绿色像素宠物。
- 标题 `fix auth bug`。
- 会话数 `3`。

### Expanded

- 用量占位：`5h 11% 4h1m | 7d 2% 6h1m`。
- 主会话：`fix auth bug`、`Claude`、`iTerm`、`27m`、`Writing middleware.ts`。
- 次会话：`backend server`、`Codex`、`Terminal`、`1h`。
- 次会话：`optimize queries`、`Gemini`、`Ghostty`、`5h`。

这些文本只用于外壳视觉验收。第二阶段接入真实额度时，fixture 仍保留在 Debug 模式作为回归画廊。

## 组件边界

### `IslandShellMotion`

只保存尺寸、曲线、延迟和 Reduce Motion 策略，不读取业务状态。

### `IslandShellShape`

只绘制顶边、凹肩、直边和下侧圆角。通过 animatable width/radius 驱动，不包含颜色和阴影。

### `IslandShellPresentation`

纯值类型，只包含 `dormant/compact/expanded`、目标尺寸和 fixture 内容。所有单元测试围绕它编写。

### `IslandShellView`

负责背景、裁剪、阴影、Compact/Expanded 内容层和手势。不得直接访问 SettingsStore、Provider 或 Agent store。

### `IslandStagePanelController`

负责屏幕锚点、固定舞台、窗口层级、点击穿透、hover grace zone、ESC 和显示/隐藏。不得拼装业务内容。

### `IslandShellFixtureGallery`

Debug-only 入口，可强制展示 dormant、compact、expanded 和 Reduce Motion 状态，保证每次视觉回归能定位到同一帧。

## 文件策略

- 保留现有 `NotchBar.swift` 中可复用的屏幕几何与 panel 基础，移除会导致 panel 自适应业务内容的路径。
- 重写 `NotchIslandView.swift` 的视觉树，使其只承载新的 Shell。
- 新增小型文件保存 motion token、fixture 与纯 presentation model，避免继续扩大单个 Swift 文件。
- 不改 Provider、Usage、AgentTask、账户、Keychain 或远程代码。
- 外壳验收前不删除旧功能实现；切换入口后，只有确认不再引用的旧视觉代码才在本阶段收尾时删除。

## 验收流程

每个状态单独验收，不把所有检查压到最后。

### 验收 A：Compact 静态形态

- 构建并启动新 bundle。
- 使用 Computer Use 捕获真实屏幕。
- 与官网 Compact 参考比较宽高、凹肩、圆角、宠物位置、文本基线和阴影。
- 所有误差控制在 2 pt 内。

### 验收 B：Expanded 静态形态

- 使用 fixture 强制进入 Expanded。
- 比较总尺寸、内边距、顶部用量占位、主次会话层级和透明区域点击穿透。
- 所有误差控制在 2 pt 内。

### 验收 C：展开与收起动效

- 分别测试 hover、click、ESC、mouse leave。
- 记录 60 Hz 和可用的高刷新率屏幕表现。
- 不允许出现面板闪烁、立即收回、重复展开、内容推挤或窗口位置漂移。
- Reduce Motion 必须在 0.14 秒内完成且无 blur/overshoot。

### 验收 D：工程质量

- 新增几何、状态转换、hover policy 和 Reduce Motion 的聚焦测试。
- `swift test --filter` 的相关测试通过。
- `make check` 通过。
- 使用打包后的 `CodexBar.app` 进行 UI 验收，不能验证旧进程或 `.build` 中的裸可执行文件。
- 不运行任何可能触发 Keychain 的真实 Provider probe。

每个验收项完成后向用户展示对比结果，得到确认后才进入下一项。外壳四项全部通过后，第二阶段的第一个功能是接入现有真实额度。

## 非目标

第一阶段明确不做：

- 真实额度读取与 Provider 切换
- Agent 会话扫描或 hooks
- 审批、问答、计划和请求队列
- 声音、通知、Glance 和 Quiet Scenes
- 精准跳转
- Settings 与 onboarding 重做
- SSH Remote 与移动通知
- 26 Agent / 20 Terminal 兼容矩阵

这些功能不会被删除，只是不参与外壳验收。
