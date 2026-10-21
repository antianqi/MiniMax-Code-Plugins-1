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

## 包里有什么

```
mcode-island/
├── .minimax-plugin/plugin.json    # MiniMax Plugin V1 manifest(包入口)
├── icon.png                       # 512x512 市场上架图标
├── skills/mcode-island/SKILL.md   # Skill:agent 怎么推状态
├── mcode-island.ps1               # WPF widget
├── mcode-island.cmd               # 命令行入口(start/stop/status/...)
├── start-island.ps1 / stop-island.ps1 / status-island.ps1 / show-island.ps1
├── pin-island.ps1 / autostart.ps1 / set-token.ps1
├── notify-island.ps1              # 状态推送助手(agent 调它)
├── wrap-tool.ps1                  # 工具调用的状态包装器
├── mcode-status-detect.ps1        # 运行时状态探测器
├── start-detect-island.ps1 / status-detect-island.ps1 / stop-detect-island.ps1
├── scripts/lib/Get-5hUsage.ps1   # 可选的 5 小时用量查询
├── scripts/lib/Protect-Text.ps1   # 密钥脱敏
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

## 运行时数据

所有状态都存在 `%APPDATA%\mcode-island\` 下:`status.json`、`caller.json`、`config.json`、
`widget.pid`、`island.log`、`widget.log`。数据不出本机。

## 披露

- **不含凭据。** 包内没有任何 token、key、secret 或个人数据。可选的 5 小时用量 token 由用户运行时提供,
  存在本机 `%APPDATA%\mcode-island\config.json`。
- **默认不联网。** 没有配置 token 时插件一次网络请求都不会发;配置了之后,探测器每 60 秒对
  `https://api.minimaxi.com/v1/coding_plan/remains` 发一次 GET。
- **没有遥测。** 不做统计分析、不上报崩溃、不打任何使用埋点。
- **不依赖第三方服务。** 没有 CDN、没有更新检查、没有任何回传行为,全部本地运行。

## 与上游插件的关系

本目录是 `plugins/antianqi/mcode-island` 的 Marketplace 上架版本,由 `marketplace/build-marketplace-package.ps1`
生成,出于 Marketplace 包规则的要求有三处差异:

1. 不包含客户端扩展目录、Claude 格式 manifest(`.claude-plugin/`)、
   agent-plugins.org 格式的 manifest,以及仅供开发使用的 smoke / test 脚本;
2. 所有 `.ps1` / `.cmd` 为纯 ASCII、UTF-8 **无 BOM**,这样 Windows PowerShell 5.1 不依赖系统代码页
   也能正确解析(上游那份保留 BOM 和中文注释);
3. widget 里的中文文案改用 XML 数字字符引用和 `([char]0x..)` 码点表示,界面仍然是中文。

中文界面、中文控制台输出和中文文档都保留:`README.zh-CN.md` 与 `skills/mcode-island/SKILL.md`
是面向中文用户的文档。

## 许可

Apache-2.0,见 `LICENSE`。
