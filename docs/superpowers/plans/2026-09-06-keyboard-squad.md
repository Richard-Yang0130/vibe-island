# Keyboard Squad Implementation Plan

**Goal:** 完成 Vibeisland A 版视觉、十角色自动固定分配、状态动效与原生验收，保留所有现有业务入口。

**Architecture:** 复用 IslandContent 与现有控制器数据流。UserDefaults 保存按 provider/sessionID 绑定的角色编号；原生 SwiftUI 角色视图读取本地动作图，按状态换帧。供应商、审批和任务跳转仍走现有服务。

**Tech Stack:** Swift 6, SwiftUI/AppKit, Swift Testing, SwiftPM；不增加依赖。

用户已授权完成所有开发和验收，无需再次确认设计或实现步骤。当前工作树包含既有未提交改动，实施前已保存 tracked diff，新增与修改仅围绕本需求。

## 实施与验收

- [x] 编写角色分配与动效时间线测试：十个活动任务不重复、排序不改变绑定、重启恢复、不同 provider 不混淆、超过十个仍固定且均衡、无手动换角色入口。
- [x] 新增 `IslandCompanion.swift` 分配/动效纯逻辑，接入 `IslandContentModel.swift` 与 `NotchBar.swift`。
- [x] 将十套已确认角色资源保存到 `Sources/CodexBar/Resources/KeyboardSquad`，原生绘制对齐双爪，缺图时保留状态文字。
- [x] 接入 `IslandSceneViews.swift` 的收起、会话、审批/问答、完成场景；保留全部请求支持的审批动作及准确 session 跳转。
- [x] 完成 A 版排版：清晰标题、供应商/状态标识、细额度条与重置信息、合理留白；原有额度详情、账户、刷新和设置可达。
- [x] 优化 `IslandShellMotion.swift`、几何/命中与生命周期：180ms 悬停、350ms 离场缓冲、300ms 容器过渡、减少动态；不可见角色停止循环；完成反馈一次且不打断焦点。
- [x] 执行相关测试、`make check`、`make test`、Debug/Release build；先验证本地包，备份安装版后更新 `/Applications/Vibeisland.app`。
- [x] 用新构建的 fixture 与真实窗口验证十角色、状态切换、点击/键盘、审批动作、长列表、中文排版、双屏/刘海与点击穿透；仅使用固定业务数据，不触发 Keychain 或真实审批。
- [x] 核对功能清单与构建/运行证据，记录未通过项并解决后才标记完成。

## 固定约束

角色自动分配并持久绑定任务，不提供手动更换。十个以内活动任务尽量唯一；超过十个使用最少占用角色，新分配不得更改既有绑定。历史绑定保留以支持重启与任务返回。角色状态与供应商身份分开呈现。动画由 Agent 状态驱动，不监控全局键盘。

验收结果和适用范围见 ../../keyboard-squad-acceptance/README.md；外屏只做了几何测试，最终现场仅有内置屏。
