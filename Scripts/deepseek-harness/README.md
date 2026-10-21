# DeepSeek Harness 接入与验证

正式插件源码为 `Sources/CodexBar/Resources/HarnessBridge.cjs`；本目录的 `bridge.cjs` 只重导出该文件，确保探针验证与应用分发的是同一份代码。插件不需要第三方依赖，只观察 Harness 的原生任务生命周期，不接管审批。

在 Vibe Island 的“任务状态”设置中启用后，检测到已安装 Harness 会自动接入。安装器把资源复制到 `~/Library/Application Support/Vibeisland/Harness/HarnessBridge-<content-hash>.cjs`，并在 `~/.dsh/profiles/desktop/cordis.patch.yml` 中维护一个独立标记块，保留其他配置；关闭任务状态会移除该块。版本化文件名用于避开 Harness 对同路径 CommonJS 模块的缓存，升级无需重启 Harness。配置无法读取时直接失败，不覆盖原文件。

灵动岛显示 Harness 的运行、待审批、完成、失败和中断状态，完成提醒沿用 5 秒自动清理。应用每 5 秒检查带心跳的私有快照，启动或断连后恢复；心跳超过 10 秒或主机退出时显示断连，不猜测任务完成。点击任务唤起 `dsh://open`；当前版本没有指定聊天的桌面协议。岛内不提供 Harness 审批按钮。

## 协议

Cordis 插件要求 `sessions`、`agents` 两个服务，监听全局 `session/event`。配置如下；目录由 Vibe Island 安装器准备，插件不会创建目录。

```json
{
  "socketPath": "/canonical/private-directory/task-events.sock",
  "statePath": "/canonical/private-directory/harness-state.json"
}
```

两个路径必须是同一目录内的绝对路径。目录必须为当前用户所有、权限 `0700`，且是 canonical 路径；插件拒绝软链接目录、软链接快照和权限不符的端点。Socket 必须属于当前用户、权限 `0600`。快照通过 `O_EXCL | O_NOFOLLOW` 创建 `0600` 临时文件后原子替换，不留下临时文件。隔离可行性探针可以省略 `statePath`，正式安装必须提供它。

每个任务事件使用已有 wire envelope：

```json
{
  "schemaVersion": 1,
  "provider": "deepseekHarness",
  "eventID": "stable-uuid-from-session-id-and-sequence",
  "payload": "base64-encoded-json"
}
```

payload 只包含 `session_id`、`turn_id`、`hook_event_name`、ISO 毫秒 `timestamp`、`harness_event_type`、`harness_event_seq`，以及可选 `cwd`、`task_title`。标题只来自实际 `session/title` 或 `sessionTitle` 服务，最多 160 个 Unicode 字符；cwd 最多 4096 字符，payload 保持在 64 KiB 内。不导出提示词、工具参数、回复正文、错误正文或审批详情。

| Harness 事件 | hook_event_name |
| --- | --- |
| `turn/start` | `UserPromptSubmit` |
| `tool/result`、`approval/decided` | `PostToolUse` |
| `approval/asked` | `PermissionRequest` |
| `turn/end(completed)` | `Stop` |
| `turn/end(aborted)` | `Interrupt` |
| `turn/end(error/blocked/max-tokens)` | `StopFailure` |

事件 UUID 由实际 `session.id:event.seq` 的 SHA256 前 16 字节生成。重复轮询不更换 UUID；按序号拒绝旧回调，结束后也不会被迟到的 progress 覆盖。`header.origin === 'subagent'` 的会话始终排除。

快照格式为：

```json
{
  "schemaVersion": 1,
  "pid": 12345,
  "generatedAt": 1792540800000,
  "events": []
}
```

`generatedAt` 为 Unix 毫秒。每个会话保存原始 turn/start 与最新 progress/approval/end，若两者相同则只存一份。事件到达时立即写入，另每 2 秒更新心跳。active 不按时间过期；终态保留 120 秒后清除。卸载时写入 `generatedAt: 0` 声明离线，并保留尚未过期的事件。

启动恢复只检查 `ctx.agents.list()` 中实际 `status === 'running'` 的会话，通过 `session.eventAt(seq)` 向后找到当前真实 turn/start 和最新状态。遇到 turn/end 就停止，不把 idle 会话的历史完成记录当作新任务。

Socket 立即尽力发送，单次连接最多等待 500 毫秒；队列按会话合并，保留 start 和最新状态，不因 progress 填满队列而丢掉终态。接收器不可用不阻止原生任务完成；应用可从快照恢复。`bridge/ready`、`bridge/stopped` 是独立诊断记录，不是任务信封。

快照上限 512 KiB，先保留 active，再保留最近终态；极端并发超过容量时会省略较旧记录，包括部分 active。单个会话只保留当前/最近一个回合。插件异常退出依靠心跳过期判定离线，不合成完成事件。

## 当前验证

在本机 DeepSeek Harness `0.2.1-rc.2` 上：

- Node 单元测试 18/18：协议、隐私过滤、子 Agent 排除、私有 Socket、真实 running 恢复、断连快照、稳定 ID、乱序防覆盖、队列合并、终态过期、容量和文件安全。
- 安装包实际 Cordis/Session/AgentLoop 测试 5/5：正常完成、失败、用户中断、接收器离线，以及任务已 running 后才加载插件的恢复。
- 引擎探针使用独立进程内的确定性模型适配器，没有外部模型调用，不向正在运行的 Vibe Island 注入任务。
- Swift 定向验证 97 项通过；路径修正后的恢复/安装器测试 8 项通过。全量 `make test` 为 793 selections / 67 groups，全部首次通过，无重试或超时；`make check` 为 0 violations。
- 原路径 `Vibeisland.app` 已完成 release 构建、签名校验并重启，正式配置已自动安装。POSIX realpath 保留 `/private/var` 的 canonical 路径，避免 Foundation 的 `/var` 别名被 Node 端拒绝。
- 桌面真实任务验收：灵动岛读回 `deepseekHarness, 运行中`，展开后显示独立 Harness 卡片；真实模型任务结束时读回 `灵动岛接入验证 sleep 15, 任务已完成`，蓝色 `DeepSeek Harness` 标识和绿色完成状态均已截图核验。随后确认完成卡片自动移除，其他运行任务继续显示。验证前的未发送草稿已恢复。

从源码仓库根目录运行：

```bash
node --test Scripts/deepseek-harness/bridge.test.cjs

ELECTRON_RUN_AS_NODE=1 '/Applications/DeepSeek Harness.app/Contents/MacOS/DeepSeek Harness' \
  --test Scripts/deepseek-harness/runtime-probe.cjs
```

探针使用 `0700` 临时目录和 `0600` 独立 Socket/快照，结束后清理。升级 Harness 后应重复执行。

`desktop-probe.cjs` 会临时修改运行中的桌面 profile，验证热加载、PID、私有心跳快照和卸载，然后还原原文件；只有明确需要验证桌面加载时才运行。它在正常结束、失败和 SIGINT/SIGTERM 时还原；检测到无法合并的并发编辑时保留备份并报告路径，不要对探针使用 SIGKILL。探针临时配置已还原，正式应用的托管插件块则保留供日常使用。
