---
name: mcode-island
description: Use this skill to publish the agent's live progress onto a Windows desktop status pill (Dynamic Island) so the user can follow the work without switching back to the terminal window. Covers pushing the idle/thinking/working/waiting/done/error states, sub-step progress, the ask_user wait case, and starting or stopping the widget. Read it before the first status push of a session.
license: Apache-2.0
metadata:
  author: antianqi
  version: 0.9.0
---

# mcode 灵动岛状态条

在用户主屏顶部显示一条常驻置顶的黑色 pill,实时显示 agent 正在做什么。用户不用切回终端窗口,就能看到进度。

## 0. 前置条件

- **仅支持 Windows**。包内所有脚本都会先做系统判断,非 Windows 上会直接报
  `mcode-island supports Windows only` 并退出,不会继续执行。
- PowerShell 5.1+。包内 `.ps1` 全部为纯 ASCII 且不带 BOM,不依赖系统代码页。
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

`ask_user` 是"等用户做决定"的时刻,从会话日志里看不出来(它和普通工具调用长得一样)。所以:

1. 调用 `ask_user` **之前**推送 `waiting`
2. 用户回答之后**立刻**推送 `done`

否则 pill 会一直停在 `working`,而用户其实正在做选择。

## 3. 子步骤进度

长任务、迭代循环、多步计划,只推粗粒度状态会让用户不知道"现在到底在干嘛"。用 `-Step` / `-Total` / `-Detail` 补充:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<plugin-root>\notify-island.ps1" `
  -State working -Message "Computer Use" -Step 3 -Total 12 -Detail "fill username field"
```

pill 显示:`step 3/12 - fill username field`。

- `-Step` 从 1 开始;不传(或传 `-1`)就退回纯状态显示
- `-Total` 可选;未知轮次就不传
- `-Detail` 是自由文本。给了它就会**替换** message,避免叠成 `Bash ok - fill username`;不给就只有步数

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

## 5. 状态探测器(可选)

除了 agent 主动推送,还有一个后台探测器会读 MiniMax Code 的会话日志,自己推断状态:

```cmd
mcode-island detect-on        REM 启动探测器(读 ~/.minimax/v2/sessions)
mcode-island detect-off       REM 停止探测器
mcode-island detect-status    REM 查看探测器状态
```

探测器不联网、不读凭据,只读本机会话日志。它和 agent 的主动推送是互补关系:agent 推的 `working` / `thinking` / `done` 不会被探测器覆盖,探测器的 `idle` 兜底可以在 agent 长时间不推时把 pill 收尾。

需要覆盖某个自定义安装位置时,用环境变量 `MINIMAX_DATA_DIR` 指到数据目录。

## 6. 启动与停止(通常由用户执行)

```cmd
mcode-island                  REM 启动 widget(幂等)
mcode-island stop             REM 停止 widget
mcode-island status           REM 打印 PID 与近期日志
mcode-island show             REM 把隐藏的 widget 重新唤起
mcode-island pin              REM 把点击目标锁定到当前前台窗口
mcode-island unpin            REM 解除锁定
mcode-island autostart-on     REM 注册开机自启
mcode-island autostart-off    REM 取消开机自启
```

登录自启(用户只需执行一次,写 `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`,不需要管理员权限):

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<plugin-root>\autostart.ps1" -Action Enable
```

它只写 `mcode-island` 和 `mcode-island-detect` 这两个具名值,**不会动同一个 Run 键下的其它开机自启项**,并且写完会核对一遍。

`Alt+F4` 只是隐藏 widget,不是关闭;用 `mcode-island show` 唤回。

**点 pill 会去哪(桌面端适配)**:每次点击都按优先级重新解析目标 ——

1. **手动 pin**(`pin.json`,由 `mcode-island pin` 写入)—— 聚焦那个窗口;
2. **桌面端应用主窗口**(同 session 内名为 `MiniMax Inside Code` / `MiniMax Code` / `Mavis`
   的进程)—— 聚焦它,不会隐藏它;
3. **来源终端窗口**(`caller.json`)—— 保留老行为:一次点击隐藏,再点一次最大化唤回。

桌面端里 agent 由应用托管,跑在应用开的终端里,藏掉那个终端并不会让 agent 停下来,
用户只会盯着一条不再变化的 pill;所以桌面端优先聚焦应用主窗口。桌面端和 CLI 同时
开着的时候,用 `mcode-island pin` 把点击目标钉回自己的终端,`mcode-island unpin` 解除。

**会话列表**:鼠标停在 pill 上会展开当前所有活着的会话(状态点、会话名、最后一条
消息、多久没动)。点一行就回到那个会话 —— 先切 Windows Terminal 标签页,会话住在
桌面端 app 里的话就把 app 切到那个对话;不会给已经在别处开着的会话再开一个终端。

## 7. 运行时数据

所有状态数据都在 `%APPDATA%\mcode-island\` 下:

| 文件 | 用途 |
| --- | --- |
| `status.json` | 当前状态(widget 每 400 ms 轮询一次) |
| `caller.json` | 来源终端窗口的 HWND / PID(没有桌面端应用时的点击兜底目标) |
| `pin.json` | 手动 pin 的点击目标(`mcode-island pin` 写入,`unpin` 清除) |
| `config.json` | pill 位置、尺寸、透明度 |
| `widget.pid` | widget 进程 PID |
| `island.log` | 状态流转历史 |
| `widget.log` | widget 内部调试日志 |

**网络访问**:没有。这个包**一次网络请求都不发**,也**不读取任何凭据** —— 不读环境变量里的 token,不读配置文件里的 token,没有 API key,没有遥测。全部在本机运行。

**5 小时用量角标**:如果 MiniMax Code 运行时把套餐用量写到了
`%APPDATA%\mcode-island\usage.json`,探测器会读它并把百分比和重置倒计时填进
pill 的角标(读不到就留空,不影响其它功能):

```json
{
  "fiveHour": { "remainingPercent": 58, "resetAtMs": 1792800000000, "unlimited": false }
}
```

`weekly` 和 `video` 是可选的。运行时没有提供这个文件时,角标就是空的 —— 插件不会自己去问接口。

## 8. 已知限制

- 仅支持 Windows 10/11(用到 WPF、`user32` / `kernel32` P/Invoke)。非 Windows 上脚本会直接退出。
- 每个用户会话只有一个 widget 实例。
- `wrap-tool.ps1` 只是状态发布器,永远不执行命令本身。
- 本 Marketplace 包不包含任何客户端事件扩展:状态由 agent 主动推送,以及可选的探测器从本机会话日志推断。
