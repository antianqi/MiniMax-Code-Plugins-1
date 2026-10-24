# Marketplace packages

Submission packages for the MiniMax Plugin Marketplace live here, one directory per plugin.

Each package directory is a self-contained [MiniMax Plugin V1](https://open.feishu.cn/) package:

```
marketplace/<plugin-name>/
├── .minimax-plugin/plugin.json    # package entry point (MiniMax Plugin V1 manifest)
├── icon.png                       # 512x512 square icon
├── skills/<skill-name>/SKILL.md
└── ...                            # files referenced by the skill
```

The directory name must equal the `name` field in `.minimax-plugin/plugin.json`, and the package
must contain at least one capability (App / MCP / Skill). Capabilities that are not included stay
as empty arrays in the manifest.

## Why a package lives next to the hosted plugin

`plugins/<owner>/<plugin>` is the repository-side plugin, published in the agent-plugins.org
format. The Marketplace accepts a different package format, so the two cannot be the same tree:

- the Marketplace entry point is `.minimax-plugin/plugin.json`, not `plugin.json`;
- the Marketplace does not accept Hooks, so the `io.minimax.mcode/` client extension and the
  `hooks` block of the Claude-format manifest stay out of the package;
- Marketplace packages are UTF-8 **without** a BOM, and Windows PowerShell 5.1 parses a BOM-less
  `.ps1` with the ANSI code page. The package therefore ships ASCII-only scripts, with the
  Chinese UI expressed through the upstream plugin and the Chinese documentation in
  `README.zh-CN.md` and `skills/<skill-name>/SKILL.md`;
- a package must not read a credential or call an API. Anything that needs the user's identity
  goes through App/Connector integration, so the 5h-usage module and the token helper are not
  part of the package;
- a package is Windows-only, and every script says so and checks it.

## Rebuilding a package

```powershell
pwsh -File marketplace/build-marketplace-package.ps1            # rebuild
pwsh -File marketplace/build-marketplace-package.ps1 -Check     # verify it is in sync
```

The builder copies the runtime files out of the hosted plugin, applies the encoding
transformations, decodes the obfuscated literals into plain strings, injects the Windows-only
guard, generates `icon.png`, and then verifies the result. It fails the build when:

- the output directory holds a file the builder does not produce (stale output);
- a `.ps1` does not parse;
- a file carries a UTF-8 BOM or a non-ASCII byte;
- a script misses the Windows-only guard;
- the package would contain a credential, an API endpoint, an outbound call, a Hook token, an
  obfuscated literal or a dependency on the MiniMax Code CLI.

`-Check` rebuilds into memory and reports the files that drifted, which is what CI should run.

The hand-written parts of a package — `.minimax-plugin/plugin.json`,
`skills/<skill-name>/SKILL.md`, `README.md` and `README.zh-CN.md` — are **not** generated. Edit
them directly; the builder only owns the runtime files and the icon.

## Auditing a package

```powershell
pwsh -File marketplace/audit-marketplace-package.ps1 -PackageDir marketplace/mcode-island
```

The audit checks the package against the submission rules: entry point and manifest schema,
directory name equals the manifest name, icon is a square PNG, Skill frontmatter is complete,
every text file is UTF-8 without a BOM, every script is ASCII-only and parses, every script
carries the Windows guard, no Hook material, no credential, no API endpoint, no obfuscated
literal, no hardcoded host path, no symlink, no LFS pointer, and the file count / size /
path-depth limits. It exits non-zero on the first violation, so it can run as a CI step.

## Submitting

The package is submitted through the
[Plugin submission form](https://vrfi1sk8a0.feishu.cn/share/base/form/shrcnbnpeor3z72fUkeHzrOE7vb)
as a GitHub source: point the repository URL at this repository, the ref at the branch or tag that
holds the package, and the subdirectory at `marketplace/<plugin-name>`. The guide is the
[MiniMax Plugin 开发与上架指南](https://vrfi1sk8a0.feishu.cn/wiki/QlTLwbAGNiACwLkWI85cFxHzn4L).

### The field values, field by field

The form has 11 questions. For `mcode-island` at v0.9.0 they are:

| #  | question                           | value                                                                          |
| -- | ---------------------------------- | ------------------------------------------------------------------------------ |
| 1  | Plugin name                        | `mcode-island`                                                                 |
| 2  | Operation type                     | 更新插件 / Update the plugin.                                                  |
| 3  | Source type                        | GitHub                                                                         |
| 4  | GitHub repository URL              | `https://github.com/antianqi/MiniMax-Code-Plugins-1`                          |
| 5  | GitHub ref                         | `marketplace-v0.9.0` (the tag that holds the package)                          |
| 6  | GitHub subdirectory                | `marketplace/mcode-island`                                                     |
| 7  | Target region                      | CN                                                                             |
| 8  | Delivery target                    | 桌面端 / Desktop                                                               |
| 9  | Maintenance authorization evidence | the block below                                                                |
| 10 | Organization or team               | 安天齐                                                                          |
| 11 | Contact email (submitter)          | `antianqi_2020@qq.com`                                                         |

Three things that cost a submission if they are wrong:

- **Question 1** must equal the name already listed in the Marketplace (`mcode-island`). A display
  name, a Chinese name or an upper-case name is rejected.
- **Question 4** takes the repository root only. A `/tree/...` URL is not accepted; the tag goes
  into question 5.
- **Question 7** takes one region per submission. Publishing to CN and US means two submissions
  with two `submission_id`s, and the operation type is chosen per region (CN is an update, US is
  a new plugin).

### The maintenance authorization evidence (question 9)

Required for an update of an already listed plugin. As of v0.9.0:

```
该 Plugin 已上架于官方 Marketplace,现有版本 mcode-island 0.5.1(可用
`mcode plugin list --marketplace official` 核验),本次为该 Plugin 的更新提交。

可人工核验的维护关系与材料:

1. 上架包所在公开仓库(仓库 owner 即本插件作者账号 antianqi):
   https://github.com/antianqi/MiniMax-Code-Plugins-1
2. 本次提交对应的 tag 与子目录(tag: marketplace-v0.9.0):
   https://github.com/antianqi/MiniMax-Code-Plugins-1/tree/marketplace-v0.9.0/marketplace/mcode-island
3. Marketplace 中已上架的 0.5.1 由同一账号 antianqi 提交,历史受理记录包括
   PLUGIN-202610210195、PLUGIN-202610220196、PLUGIN-202610220200。
4. 插件源码与上架包在同一仓库维护:源码在 plugins/antianqi/mcode-island,
   上架包由 marketplace/build-marketplace-package.ps1 从该源码生成,
   并由 marketplace/audit-marketplace-package.ps1 自动审计(245 项检查,0 失败)。

本次更新(v0.8.0 → v0.9.0)内容:
- v0.8.0 点击行为适配桌面端:点 pill 聚焦桌面应用主窗口(MiniMax Inside Code /
  MiniMax Code / Mavis),不再隐藏终端;优先级为 手动 pin > 桌面端应用窗口 >
  来源终端窗口(保留原来的显隐切换)。手动 pin 从 caller.json 移到独立的
  pin.json,不再被状态流转覆写。
- v0.8.1 修状态探测器的一个真实缺陷:会话日志的单行可以很大(读截图会把
  base64 图片写进同一行,实测 200KB - 560KB),探测器原来只回看末尾 64KB,
  遇到这种大行就解析失败并回退到"上一条缓存的推断"——而那条推断属于上一个
  会话,于是新对话里状态条一直停在上一个任务完成的状态。现在改为按需扩大
  回看窗口直到读到完整的一行,缓存按 路径+修改时间 双键,读失败时不再借用
  别的会话的状态。
- v0.8.2 两条线正式分家:源码里只留一个开关 $script:clickPrefers,本仓库的
  CLI 版是 'terminal'(点一下隐藏终端、再点唤回),Marketplace 包由构建器把
  这一行翻成 'app'(点一下聚焦桌面应用主窗口)。翻不到这行,构建直接失败,
  不会把 CLI 的行为静默发给桌面端用户。pin 在两个形态里都是最高优先级。
- v0.9.0 上架多会话列表:鼠标停在 pill 上会展开当前所有活着的会话(状态点、
  会话名、最后一条消息、多久没动),点一行就回到那个会话 —— 先切 Windows
  Terminal 标签页;会话住在桌面端 app 里的话,就把 app 切到那个对话(app
  侧边栏那一行是无障碍名等于会话名的按钮,widget 用 UI Automation 点它)。
  点一行不会给已经在别处开着的会话再开一个终端。

包仍满足上架规则:纯 ASCII、无 BOM、无凭据、无 Hook、仅 MiniMax Plugin V1
manifest,所有 .ps1 带 Windows 平台守卫。
```

Update the version, the tag, the commit id and the changelog paragraph when a new package
version is cut; everything else in the table stays as it is.
