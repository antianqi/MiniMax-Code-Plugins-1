---
name: mcode-island
description: Use this skill to publish the agent's live progress onto a Windows desktop status pill (Dynamic Island) so the user can follow the work without switching back to the terminal window. Covers pushing the idle/thinking/working/waiting/done/error states, sub-step progress, the ask_user wait case, and starting or stopping the widget. Read it before the first status push of a session.
license: Apache-2.0
metadata:
  author: antianqi
  version: 0.4.0
---

# mcode 灵动岛状态条

在用户主屏顶部显示一条常驻置顶的黑色 pill,实时显示 agent 正在做什么。用户不用切回终端窗口,就能看到进度。

## 0. 前置条件

- Windows 10/11,PowerShell 5.1+。包内 `.ps1` 全部为 ASCII 编码,不受系统代码页影响。
- widget 必须在运行。检查:`powershell -NoProfile -ExecutionPolicy Bypass -File "<plugin-root>\status-island.ps1"`,没有输出就先启动(见「启动与停止」)。
- **`<plugin-root>`** = 包含 `notify-island.ps1` 的目录,即本文件(`skills/mcode-island/SKILL.md`)往上两级。MiniMax Code 通常会导出 `${PLUGIN_ROOT}`(PowerShell 里是 `$env:PLUGIN_ROOT`)。下面所有命令请把 `<plugin-root>` 替换成实际绝对路径。

所有脚本都必须通过明确的解释器调用,不要直接执行 `.ps1`:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<plugin-root>\notify-island.ps1" -State working -Message "read source tree"
```

脚本成功时输出 `OK: <state> - <message>`,失败时输出 `FAIL: <reason>` 并以退出码 1 结束。**每次推送后检查退出码**;`FAIL` 说明状态没有写进去,不要当成已推送。

## 1. 什么时候推送

| 时机 | state | message 示例 |
| --- | --- | --- |
| 收到用户任务,开始推理 | `thinking` | (可留空) |
| 即将调用任意工具 | `working` | `bash: npm test` |
| 工具返回 0,汇报结果之前 | `done` | `3 files modified` |
| 工具需要审批 / 即将调用 `ask_user` | `waiting` | `bash: needs approval` |
| 工具失败、抛异常、退出码非 0 | `error` | `compile failed: missing import` |
| 本轮结束,等用户下一条指令 | `idle` | (可留空) |

**不要连续推送两个完全相同的状态和文案** —— widget 会按 state+message 去重。只在状态变化时推,或者每次带上新的 message。

## 2. `ask_user` 必须单独处理

`ask_user` 是"等用户做决定"的时刻,detector 从会话日志里看不出来(它和普通工具调用长得一样)。所以:

1. 调用 `ask_user` **之前**推送 `waiting`
2. 用户回答之后**立刻**推送 `done`

否则 pill 会一直停在 `working`,而用户其实正在做选择。

## 3. 子步骤进度

长任务、迭代循环、多步计划,只推粗粒度状态会让用户不知道"现在到底在干嘛"。用 `-Step` / `-Total` / `-Detail` 补充:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<plugin-root>\notify-island.ps1" `
  -State working -Message "Computer Use" -Step 3 -Total 12 -Detail "fill username field"
```

pill 显示:`step 3/12 · fill username field`。

- `-Step` 从 1 开始;不传(或传 `-1`)就退回纯状态显示
- `-Total` 可选;未知轮次就不传
- `-Detail` 是自由文本。给了它就会**替换** message,避免叠成 `Bash ok · fill username`;不给就只有步数

三个参数都是可选的,老调用方不传也不受影响。

## 4. 批量包装器 `wrap-tool.ps1`

`wrap-tool.ps1` **只负责发布状态,不执行命令**。命令要用你自己的工具跑,跑完再让它发布结果:

```powershell
# 步骤 1:调用工具之前,宣布 working
powershell -NoProfile -ExecutionPolicy Bypass -File "<plugin-root>\wrap-tool.ps1" -Tool bash -Command "npm test" -Description "run tests"

# 步骤 2:工具返回之后,发布结果
powershell -NoProfile -ExecutionPolicy Bypass -File "<plugin-root>\wrap-tool.ps1" -Tool bash -Command "npm test" -ExitCode $LASTEXITCODE
```

`-ExitCode` 的语义:`0` → `done`;命中 `-WaitingExitCodes`(默认 `[1]`)→ `waiting`;其它 → `error`。包装器原样返回退出码,不影响调用方的 shell。

`-Tool` 接受 `bash|read|write|edit|glob|grep|web|task|notebook`,会生成对应的 done 文案(例如 `read C:\path`、`edited file.cs`)。read/write/edit/glob/grep 的命令仍然由你自己的工具执行,包装器只发布状态。

## 5. 启动与停止(通常由用户执行)

```cmd
mcode-island                  REM 启动 widget(幂等)
mcode-island stop             REM 停止 widget
mcode-island status           REM 打印 PID 与近期日志
mcode-island show             REM 把隐藏的 widget 重新唤起
mcode-island pin              REM 把焦点目标锁定到当前前台窗口
mcode-island unpin            REM 解除锁定
mcode-island autostart-on     REM 注册开机自启
mcode-island autostart-off    REM 取消开机自启
mcode-island detect-on        REM 启动状态探测器
mcode-island detect-off       REM 停止状态探测器
mcode-island detect-status    REM 查看探测器状态
```

登录自启(用户只需执行一次,写 `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`,不需要管理员权限):

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<plugin-root>\autostart.ps1" -Action Enable
```

`Alt+F4` 只是隐藏 widget,不是关闭;用 `mcode-island show` 唤回。

## 6. 运行时数据

所有状态数据都在 `%APPDATA%\mcode-island\` 下:

| 文件 | 用途 |
| --- | --- |
| `status.json` | 当前状态(widget 每 400 ms 轮询一次) |
| `caller.json` | 来源终端窗口的 HWND / PID(点击 pill 回切用) |
| `config.json` | pill 位置、尺寸、透明度,以及可选的 `planApiToken` |
| `widget.pid` | widget 进程 PID |
| `island.log` | 状态流转历史 |
| `widget.log` | widget 内部调试日志 |

**网络访问**:默认**完全不出网**。只有当用户配置了 5 小时用量 token(`config.json:planApiToken`,或环境变量 `MINIMAX_OAUTH_TOKEN` / `MINIMAX_API_KEY`)时,探测器才会访问 `api.minimaxi.com/v1/coding_plan/remains`,限频 60 秒一次 GET。没有 token 就一次请求都不会发。

## 7. 已知限制

- 仅支持 Windows 10/11(用到 WPF、`user32` / `kernel32` P/Invoke)。
- 每个用户会话只有一个 widget 实例。
- `wrap-tool.ps1` 只是状态发布器,永远不执行命令本身。
- 本 Marketplace 包不包含客户端事件扩展目录:状态完全由 agent 主动推送,以及可选的探测器从运行时会话日志推断。
