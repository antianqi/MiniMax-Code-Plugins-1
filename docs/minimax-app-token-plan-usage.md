# MiniMax 运行时:把 token plan 用量落盘(或暴露给插件)

> 背景:mcode-island 插件已上架 MiniMax Code Plugin Marketplace(CN 区)。它的 5 小时用量角标
> 此前由插件自己带凭据查接口实现,审核认为这与 Marketplace 规则冲突(插件不应自行处理用户
> 凭据、不应自行出网),要求整改。
>
> 结论:**能力已经在运行时里,只差一个出口。** 本文只描述这个出口,以及在出口落地前插件侧的
> 现状。附件:插件侧已实现的读取器(零凭据)与端点细节。

## 1. 诉求(第一档,推荐):把已经算出来的用量落盘

MiniMax Code 运行时已经用**用户自己的登录态**解析了 token plan,并在自己的界面里显示它:

- mcode CLI 的 launcher 有一个 "MCode status" 本地状态面板,里面有 `Plan`(套餐/到期/积分)
  和 `Quota`(`5-hour` / `Weekly` / `Video`)三组字段,页脚写的是
  **"Local view · credentials hidden"**;
- 对应的运行时数据模型是:

```ts
tokenPlanQuota = {
  fiveHour: { remainingPercent: number; resetAtMs: number; unlimited: boolean };
  weekly:   { remainingPercent: number; resetAtMs: number; unlimited: boolean };
  video:    { remainingCount?: number; totalCount?: number };
}
tokenPlanQuotaState = 'available' | 'not-subscribed' | 'unavailable'
tokenPlanSummary = { tier?: string; expiresAtMs?: number; creditBalance?: number }
```

**请求**:请把这份数据落到一个本地文件(或暴露成一个 Agent 可读的工具 / 一个只读接口),
让桌面端插件只读它。

这不需要新的能力,不需要新的鉴权通道,也不需要 App/Connector 接入流程 —— 只是把已经在内存里
的数值写出来。凭据仍然只存在于运行时内部,插件拿不到、也不需要。

## 2. 契约(插件侧已经按这个实现)

```json
// %APPDATA%\mcode-island\usage.json
{
  "fetchedAtMs": 1792800000000,
  "fiveHour": { "remainingPercent": 58, "resetAtMs": 1792800000000, "unlimited": false },
  "weekly":    { "remainingPercent": 40, "resetAtMs": 1792900000000, "unlimited": false },
  "video":     { "remainingCount": 12, "totalCount": 40 }
}
```

- 字段名与运行时**完全一致**(就是上面 `tokenPlanQuota` 的结构)⇒ 运行时可以直接把现有对象
  序列化出来,不需要做任何字段映射 ✓
- `fiveHour` 必需,`weekly` / `video` 可选
- `resetAtMs` 是绝对时间戳(毫秒);插件会换算成"还剩多久重置"显示
- `unlimited: true` 表示没有百分比可显示,插件会只显示重置倒计时
- 读取路径(按顺序,第一个存在且能解析的生效):
  1. `%MCODE_PLAN_USAGE_FILE%` 环境变量指定的路径
  2. `%APPDATA%\mcode-island\usage.json` ← **建议的规范落点**
  3. `%USERPROFILE%\.minimax\usage.json`(运行时自己的数据目录,兜底)

⇒ 插件侧**已经实现**了这个读取器(`scripts/lib/Plan-Usage.ps1`),并且上架包里就是它:
包内 `planApiToken` / `Resolve-PlanToken` / `MINIMAX_API_KEY` / `MM-API-Source` 全部为 0 处,
一次出站请求都没有。运行时把文件落下来,角标立刻就有数据;没有文件,角标留空,其它功能不受影响。

## 3. 需要确认的 4 件事

1. 落点用 `%APPDATA%\mcode-island\usage.json` 可以吗?还是希望放在运行时自己的数据目录?
2. 写入频率:每次刷新后写,还是定时(例如 60 秒)写一次?插件侧按"读到即用"处理,两种都行。
3. 字段是否就用上面 `tokenPlanQuota` 的原样结构?如果运行时还有别的字段,一并写进来也可以,
   插件只读自己需要的几个。
4. 桌面端(Mavis)与 CLI 是否都写同一个路径?如果两个运行时路径不同,告诉我各自的路径,
   插件侧加候选即可。

## 4. 备选(第一档不可行时)

**第二档:App / Connector。** 把"查询当前账号的 token plan 用量"做成一个 Connector provider,
凭据由 Connector 注入,插件不接触。插件侧改动:包内加 `mcode-island.app.json`
(`{"schemaVersion":1,"provider":"<provider>"}`),manifest 的 `apps` 引用它,Skill 改成调用
`mcode-tools connector call connector__<provider>__<tool>`。这条要走 App 接入与联调流程,
周期比第一档长。

**第三档:第三方按官方请求形状自建。** 如果第一、二档都不做,插件可以照运行时自己的请求形状
实现(参考下面的端点),但仍需用户显式提供并授权凭据 —— 那正是 Marketplace 规则不喜欢的形态,
仅作为兜底。

## 5. 附:官方请求形状(第三档需要,第一二档不需要)

身份 → 分组 → 用量,三步:

| 步骤 | 端点 |
| --- | --- |
| 身份 | `GET https://agent.minimaxi.com/matrix/api/v1/user/get_user_extra_info` |
| 分组 | `GET https://agent.minimaxi.com/matrix/api/v1/commerce/get_membership_info` |
| 用量 | `GET https://www.minimaxi.com/v1/api/openplatform/coding_plan/remains`(EN 域 `platform.minimax.io`) |

用量请求的头:

```
token: <accessToken>          # 运行时登录态的 access token
X-Group-Id: <personalOpGroupId>
```

响应是 `model_remains[]`,每一项含 `interval` / `weekly` / `current_interval_total_count` 等字段。

## 6. 插件侧现状

| | 状态 |
| --- | --- |
| 读取器 | 已实现并已上架(包内 `scripts/lib/Plan-Usage.ps1`)✓ |
| 零凭据校验 | 上架包审计 227 项 0 失败;包内无 token/URL/出网调用 ✓ |
| 凭据路径 | 仅仓库版保留(用户显式授权 + DPAPI 加密),上架包不携带 ✓ |
| 验证 | 删掉 config.json 里的 token、只留 usage.json,探测器仍报 `usage5h=58` 与重置倒计时 ✓ |
