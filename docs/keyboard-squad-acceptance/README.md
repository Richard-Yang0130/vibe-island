# Keyboard Squad 原生验收记录

## 用户确认与实现边界

A 版清晰排版、十个同风格键盘角色；角色系统自动分配并持久绑定任务，不提供手动更换。任务/供应商身份仍独立显示。动画由 Agent 状态驱动，不监听用户键盘。现有工作树包含其他未提交改动，本次未重置或提交它们。

## 代码与测试证据

- 角色分配：IslandCompanionTests 验证10个唯一、重排不换、重新构造store恢复、11个溢出不改变旧绑定、provider/session组合键及attention一致。
- 资源与动效：十套图片全部可解码；六帧索引有效；左右爪循环、完成只反馈一次、Reduce Motion 保留等待/故障标识。
- 生命周期：完成2.2秒后允许自动收起，鼠标/键盘焦点/置顶阻止打断，等待操作不自动消失；新审批升级已展开视图，已展示事件去重。
- make check：1708文件，零违规。完整日志 make-check.log。
- make test：786 selections，66组首轮通过，零失败/重试/超时。完整日志 make-test.log。

## 原生窗口实际操作

独立DEBUG入口 --keyboard-squad-preview，进入真实 IslandShellView/IslandSessionCardView/IslandCompanionView，不初始化真实账户、UsageStore、Keychain或hooks。

- ten-session overview：实际渲染角色、标题、状态、供应商、额度条与工具栏。
- ScrollToBottom 后点击第10项，动作日志 `openSession: codex / qa-session-10`。
- 切换11项后滚动末尾并点击，日志 `openSession: claude / qa-session-11`。
- 刷新、设置、供应商菜单分别产生 refresh / settings / provider: codex。
- 审批4个按钮分别产生 qa-approval-1 / deny、allowOnce、allowAlways、bypass，未触发父容器折叠；使用假请求，不发送真实审批。
- 问答页仍提供准确任务入口和关闭动作。
- Reduce Motion 开关可操作；compact 使用原生 Button，包含独立状态点；156pt物理刘海几何的内容在两侧区域。
- 工具截图已在当前任务的原生验收记录中展示。离屏 ImageRenderer 不支持完整ScrollView/Menu，所以未把离屏截图当作完整界面证据；仅保留十角色原生绘制图。

## 启动现场问题

安装包启动取样发现首次 Widget 缓存读取在主线程等待文件打开。已将首次读取放到后台并合并期间重复请求，读完后才生成和保存最新快照，避免覆盖尚未读取的旧额度。延迟加载/读取失败/账户隔离专项19测试通过；该修复包含在最终全量回归中。未修改系统权限或用户缓存。

## 发布

最终Release已安装到 /Applications/Vibeisland.app。源包与安装后二进制SHA256一致：`9cc76cbeebce44a456a170fb86f558a44c92da9c210643aa157574362dfe62af`。codesign深度严格验证通过。安装版可由原生菜单打开设置窗口，真实任务已产生1个持久角色绑定。构建时间与进程见release.json。

当前仅连接1440×932内置屏：物理刘海宽156、高28；实际stage窗口位于(440,0)，大小560×520，与中心锚点吻合。外屏负坐标/偏移与无刘海由自动化几何测试覆盖；未声称完成外接屏实机验证。

保留原安装版备份：/Users/lisongyang/workspace/项目/CodexBar/设计预览/发布备份/Vibeisland-before-keyboard-squad-20260906.app。

本记录为安装验收时的快照；原始测试日志与启动取样保留在本地，Git 收录验收摘要和 release.json。后续提交包含完整功能所依赖的会话审批层、角色资源、原生界面、启动修复及测试。
