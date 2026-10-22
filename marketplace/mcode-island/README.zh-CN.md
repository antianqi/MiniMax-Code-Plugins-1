# mcode 灵动岛状态条

给 MiniMax Code 用的 Windows 桌面状态条。agent 在思考、跑工具、等审批、做完或者出错时,pill 会实时显示出来,
用户不用切回终端窗口就能看到进度。

![状态](assets/state-working.png)

## 试一下

```text
在桌面顶部开一条状态条,让我不用切回窗口也能看到你在做什么
```

预期结果:主屏顶部中央出现一条深色 pill,并在 agent 工作期间持续更新。

## 六种状态

| 状态 | 含义 |
| --- | --- |
| `idle` | 等待用户输入 |
| `thinking` | 正在推理,还没调工具 |
| `working` | 正在执行工具 |
| `waiting` | 工具需要审批或用户输入 |
| `done` | 这一步做完了,还有后续 |
| `error` | 工具或步骤失败 |

## 运行要求

- **仅支持 Windows 10/11**。包内每个脚本都会先做系统判断,其它系统上直接报
  `mcode-island supports Windows only` 并退出,不会走到 WPF 里面才炸。
- PowerShell 5.1+。包内 `.ps1` 全部是纯 ASCII 且不带 BOM,任何代码页下解析结果一致。

## 包里有什么

```
mcode-island/
├── .minimax-plugin/plugin.json    # MiniMax Plugin V1 manifest(包入口)
├── icon.png                       # 512x512 市场上架图标
├── skills/mcode-island/SKILL.md   # Skill:agent 怎么推状态
├── mcode-island.ps1               # WPF widget
├── mcode-island.cmd               # 命令行入口(start/stop/status/...)
├── start-island.ps1 / stop-island.ps1 / status-island.ps1 / show-island.ps1
├── pin-island.ps1 / autostart.ps1
├── notify-island.ps1              # 状态推送助手(agent 调它)
├── wrap-tool.ps1                  # 工具调用的状态包装器
├── mcode-status-detect.ps1        # 运行时状态探测器
├── start-detect-island.ps1 / status-detect-island.ps1 / stop-detect-island.ps1
├── scripts/lib/Protect-Text.ps1   # 密钥脱敏
├── scripts/lib/Status-Store.ps1   # 跨进程 status.json 协议
├── assets/                        # 状态截图
├── README.md / README.zh-CN.md
└── LICENSE                        # Apache-2.0
```

## 使用

先启动一次 widget(agent 也可以替你启动):

```cmd
mcode-island
```

之后 agent 在干活过程中推状态:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "<plugin-root>\notify-island.ps1" -State working -Message "read source tree"
```

完整流程(子步骤进度、`ask_user` 等待场景等)见 `skills/mcode-island/SKILL.md`。

状态探测器是可选的。开着的时候它会读本机 MiniMax Code 的会话日志
(`~/.minimax/v2/sessions`,或 `$env:MINIMAX_DATA_DIR` 指定的目录)自己推断状态,
agent 不推的时候 pill 也能继续动。它只读本机文件。

## 开机自启

`mcode-island autostart-on` 会在 `HKCU\Software\Microsoft\Windows\CurrentVersion\Run` 下写两个具名值
(`mcode-island` 和 `mcode-island-detect`)。它只在键不存在时创建这个键,只写自己那两个值,
写完还会核对一遍:同一个 Run 键下别的开机自启项一个都没少。

## 运行时数据

所有状态都存在 `%APPDATA%\mcode-island\` 下:`status.json`、`caller.json`、`config.json`、
`widget.pid`、`island.log`、`widget.log`。数据不出本机。

## 披露

- **不含凭据。** 包内没有任何 token、key、secret 或个人数据;不从环境变量读凭据;也不保存任何凭据。
  这个包里没有 API 客户端。
- **不联网。** 包内一次出站请求都没有。状态探测器只读本机会话日志,widget 完全本地绘制。
- **没有遥测。** 不做统计分析、不上报崩溃、不打任何使用埋点。
- **不依赖第三方服务。** 没有 CDN、没有更新检查、没有任何回传行为。
- **不含客户端事件扩展。** 包内没有事件扩展目录,也没有事件声明。状态由 agent 主动推送,
  以及可选的本机探测器推断。

## 与上游插件的关系

本目录是 `plugins/antianqi/mcode-island` 的 Marketplace 上架版本,由 `marketplace/build-marketplace-package.ps1`
生成,出于 Marketplace 包规则的要求有四处差异:

1. 包入口是 `.minimax-plugin/plugin.json`;agent-plugins.org 格式的 manifest 和 Claude 格式的
   manifest 不属于 Marketplace 包;
2. 客户端事件扩展目录和仅供开发使用的 smoke / test 脚本不属于 Marketplace 包;
3. 包内文本文件是 UTF-8 **无 BOM**,而 Windows PowerShell 5.1 读无 BOM 的 .ps1 会按 ANSI 代码页解析。
   所以这里的脚本是纯 ASCII 的,上游那份的中文注释不随包发布;
4. 界面文案这里是英文;中文界面、中文控制台输出和完整中文文档在上游插件以及
   `README.zh-CN.md`、`skills/mcode-island/SKILL.md` 里。

上游的 `plugins/antianqi/mcode-island` 保留中文界面、5 小时用量角标和本机安装流程。

## 许可

Apache-2.0,见 `LICENSE`。
