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
  Chinese UI expressed as XML character references and `([char]0x..)` code points.

Everything else — the widget, the detector, the state machine, the Chinese UI — is the same code.

## Rebuilding a package

```powershell
pwsh -File marketplace/build-marketplace-package.ps1            # rebuild
pwsh -File marketplace/build-marketplace-package.ps1 -Check     # verify it is in sync
```

The builder copies the runtime files out of the hosted plugin, applies the encoding
transformations and the Chinese-to-ASCII substitutions, generates `icon.png`, and then verifies
that every `.ps1` still parses and that no file carries a BOM or a non-ASCII byte. `-Check`
rebuilds into memory and reports the files that drifted, which is what CI should run.

The hand-written parts of a package — `.minimax-plugin/plugin.json`,
`skills/<skill-name>/SKILL.md`, `README.md` and `README.zh-CN.md` — are **not** generated. Edit
them directly; the builder only owns the runtime files and the icon.

## Auditing a package

```powershell
pwsh -File marketplace/audit-marketplace-package.ps1 -PackageDir marketplace/mcode-island
```

The audit checks the package against the submission rules: entry point and manifest schema,
directory name equals the manifest name, icon is a square PNG, Skill frontmatter is complete,
every text file is UTF-8 without a BOM, every script is ASCII-only and parses, no Hook
material, no credential-shaped literal, no hardcoded host path, no symlink, no LFS pointer, and
the file count / size / path-depth limits. It exits non-zero on the first violation, so it can
run as a CI step.

## Submitting

The package is submitted through the
[Plugin submission form](https://vrfi1sk8a0.feishu.cn/share/base/form/shrcnbnpeor3z72fUkeHzrOE7vb)
as a GitHub source: point the repository URL at this repository, the ref at the branch or tag that
holds the package, and the subdirectory at `marketplace/<plugin-name>`. The guide is the
[MiniMax Plugin 开发与上架指南](https://vrfi1sk8a0.feishu.cn/wiki/QlTLwbAGNiACwLkWI85cFxHzn4L).
