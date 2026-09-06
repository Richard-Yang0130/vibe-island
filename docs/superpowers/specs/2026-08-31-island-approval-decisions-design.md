# 岛上审批决策回传设计

> 日期：2026-08-31
> 前置：`2026-08-31-island-content-states-design.md` §3（协议核实结论）
> 分支：`feature/vibe-island-shell`
> 目标：在刘海岛上按下 Deny / Allow 能真正把决策送回 Claude Code 和 Codex

## 1. 目标与边界

让用户在岛上做出的授权决策真正生效，不再只能「跳回终端自己答」。

**在范围内**：`PermissionRequest` 决策回传、双向传输、请求生命周期、按钮能力矩阵、失败降级、开关与引导。

**不在范围内**：问答（`AskUserQuestion`）—— 两边 hook 事件表里都没有对应事件；计划评审；`PreToolUse` 拦截（我们要的是「需要用户决定时」，不是「每次工具调用」）。

## 2. 这件事最大的风险不是做不出来

改成同步 hook 之后，**CodexBar 里的任何缺陷都会卡住用户真实 agent 的每一次授权**。比这更糟的一条：Claude 在无法弹窗的会话（headless、后台 subagent）里，**没有任何 hook 给出决策时会直接拒绝**。也就是说一个挂掉的岛可能把用户的后台任务全线自动拒绝。

因此下面四条是架构约束，不是可选的打磨项：

1. **默认关闭。** 设置项 `agentTaskApprovalsEnabled` 默认 `false`。关闭时 hook 文档写的仍是今天的 `async: true` 遥测处理器，行为与现在完全一致。
2. **两级超时，全部 fail-open。** 连不上 app（250ms 内）→ 立刻无输出退出；连上但用户没在决策超时内回答 → 无输出退出。无输出 = 无决策 = 回落各自的正常授权流程。
3. **独立 socket。** 审批走 `/tmp/codexbar-<uid>-agent-approval.sock`，与遥测事件的 socket 完全分离。任一条链路故障不影响另一条。
4. **helper 保持愚蠢。** 不读设置、不做策略判断、不解析 hook 语义。只做：发请求 → 等一个决策 → 按 provider 序列化 → 打印。所有策略在 app 里。

## 3. 为什么要新开一个 socket

现有 `AgentTaskEventSocketServer` 的分帧**依赖客户端发完即关连接**：服务端把 `receive` 回调里的 `isComplete` 当作消息边界，而那个 `isComplete` 实际是客户端 `connection.cancel()` 造成的流结束。请求/响应要求连接保持存活，这个前提直接不成立。

在同一 socket 上混入第二种分帧会让两条链路互相牵连。新开 socket + 明确分帧，隔离彻底且改动面更小。遥测那条一行不改。

## 4. 线协议

长度前缀分帧：4 字节大端长度 + JSON body。请求与响应各一帧，同一连接。

**请求（helper → app）**

```json
{
  "schemaVersion": 1,
  "provider": "claude",
  "requestID": "claude:<sha256(payload)>",
  "payload": { "…": "hook 原样 stdin" }
}
```

**响应（app → helper）**

```json
{ "schemaVersion": 1, "requestID": "…", "decision": { "behavior": "allow" } }
```

`decision` 为 `null` 表示「不做决策」，helper 静默退出。

**helper stdout** —— 两边 agent 的输出形状恰好一致，只有可用字段不同：

```json
{ "hookSpecificOutput": { "hookEventName": "PermissionRequest",
  "decision": { "behavior": "allow" } } }
```

## 5. 能力矩阵

| 动作 | Claude Code | Codex |
| --- | --- | --- |
| Deny | `behavior:"deny"` + `message` | 同左 |
| Allow Once | `behavior:"allow"` | 同左 |
| Allow All | `allow` + `updatedPermissions:[addRules…]` | **不支持** |
| Bypass | `updatedPermissions:[{type:"setMode",mode:"bypassPermissions"}]` | **不支持** |

Codex 侧 `updatedInput` / `updatedPermissions` / `interrupt` 是保留字段且 **fail closed** —— 返回它们会让整个 hook 判定失败并放行。所以序列化层必须按 provider **主动裁剪**，不能依赖对端忽略未知字段。这条是本设计里最容易写出静默故障的地方，单测直接锁死。

Allow All 的规则不由我们猜：Claude 的 `PermissionRequest` 输入自带 `permission_suggestions` 数组，就是权限对话框里那几个「始终允许」选项。把用户选中的那条原样回传即可，文档明确说这等价于用户在对话框里选了该项。没有 `permission_suggestions` 时，Allow All 按钮不出现。

Bypass 还有一层前置条件：仅当会话本身以 bypass 可用的方式启动时 `setMode` 才生效，否则是 no-op。按钮需要标注这一点，不能让用户以为点了就一定生效。

## 6. 组件

| 文件 | 职责 |
| --- | --- |
| `AgentTaskApprovalWire.swift`（Core） | 帧编解码、请求/响应模型、socket 路径 |
| `AgentTaskApprovalDecision.swift`（Core） | 决策模型 + 按 provider 裁剪的序列化；纯函数 |
| `AgentTaskApprovalCapability.swift`（Core） | 能力矩阵：provider + `permission_suggestions` → 可用动作列表 |
| `AgentTaskApprovalServer.swift`（App） | 监听审批 socket，登记 pending，等决策，回帧 |
| `AgentTaskApprovalStore.swift`（App） | pending 队列、请求身份、幂等、超时回收 |
| `CLIApprovalCommand.swift`（CLI） | helper：发请求、等决策、打印、两级超时 |

`AgentTaskHookDocument` 增加按事件区分同步/异步的能力；启用审批时 `PermissionRequest` 写同步处理器（`timeout: 90`，无 `async`），其余事件保持 `async: true, timeout: 1`。

## 7. 请求生命周期

```text
hook 触发 → helper 连 socket（250ms）
  └ 失败 → 无输出退出（正常授权流程）
连上 → 发请求帧 → app 登记 pending → 岛升 approval 场景
  ├ 用户点按钮 → 回决策帧 → helper 打印 → agent 执行
  ├ 决策超时（默认 60s）→ 回 null → helper 静默退出
  └ app 退出/连接断 → helper 静默退出
```

请求身份取 `provider + payload 摘要`，与遥测事件的 `id` 同构。同一 requestID 重复到达时复用既有 pending，不新建 —— 避免同一次授权在岛上堆两张卡。已决策的请求不能被延迟事件复活。

超时必须**短于 hook 的 timeout**：hook 配 90s，决策超时 60s，留 30s 余量保证 helper 总能自己干净退出，而不是被 agent 杀掉。

## 8. Codex 的额外一步：信任

Codex 非托管 hook 需经 `/hooks` 审阅并信任才生效，且信任绑定 hook 内容 hash —— 我们改写 `hooks.json` 后信任会失效，需要重新信任。这意味着：

- 启用审批后，Codex 侧必须提示用户去终端跑 `/hooks` 信任，否则装了等于没装，且**没有任何报错**。
- 每次 hook 命令变更（升级换路径）都会使信任失效，需要重新引导。

设置面板里给 Codex 单独一行状态与引导文案，不能和 Claude 合并成一个「已安装」。

另一条已知偏差：Codex 的 `PermissionRequest` 对自动审核的请求也会触发（openai/codex#28833 正在请求 `approvals_reviewer` 字段区分）。在该字段落地前，Codex 侧可能弹出用户本来根本看不到的授权。这一条无法在我们这侧修复，只能在文档和设置说明里写清楚。

## 9. 验收

已通过（`swift test --filter Approval`，33 项）：

- 关闭开关时，全部事件仍写 `async: true, timeout: 1`，与本功能之前一致。
- 开启时只有 `PermissionRequest` 变同步（无 `async`，`timeout: 90`），其余事件保持 async。
- provider 裁剪：Codex 决策序列化后**不含** `updatedInput`/`updatedPermissions`/`interrupt`。
- 能力矩阵：Codex 只给两档；无 `permission_suggestions` 时不产出 Allow All。
- 动作降级：provider 不支持的动作退回 allow-once，绝不扩大授权范围。
- 帧编解码往返、超长帧拒绝、截断帧返回 `incomplete` 而非崩溃。
- 真实 socket 往返：真 helper ↔ 真 server，决策正确落到 helper stdout。
- 无决策时 helper stdout 为空。
- app 未运行时 helper 快速 fail-open。
- 幂等：同一 requestID 两次到达只产生一个 pending，两个调用者拿到同一答案。
- 超时与 drain 均释放阻塞中的 agent。
- requestID 不匹配的响应被丢弃。

已通过（视觉）：

- `--island-fixture-scene approval` 渲染工具名、真实命令、路径与四档色阶（灰→白→橙→红）。

**尚未验收**：真实 Claude Code 会话端到端。需要把 `agentTaskApprovalsEnabled` 打开并改写 `~/.claude/settings.json`，会让用户本机 agent 的授权真正走阻塞路径 —— 这一步应由用户自己在知情下开启，不由实现方代劳。开启后的手工验收步骤：

1. 设置里打开「在岛上做授权决策」。
2. Codex 侧在终端执行 `/hooks` 信任更新后的 hook。
3. 在 Claude Code 里触发一次需要授权的命令，确认岛升起 approval 场景。
4. 点 Deny，确认终端显示被拒绝且带上 `island_denied_from_codexbar` 文案。
5. 退出 CodexBar 后再触发一次，确认 agent 在 250ms 内回落到终端提问。
