# 控制面 UI 制作与对接指南

核对日期：2026-11-05。工作树：`D:\github\Ringwin-control-plane`，分支
`control-plane-and-operator-ui`。基于 `93758745` 及当前工作区中的重复命令默认截止时间修复。
本文描述当前实现，不代表运行服务已配置全部能力，也不授予 Demo 或生产资格。

## 1. 源码入口与职责

| 文件 | 对接时查看的内容 |
|---|---|
| [control_plane_web.py](../python/control_plane_web.py) | HTTP 路由、会话、CSRF、RiskWarning、响应封装 |
| [operator_ui.html](../python/operator_ui.html) | 现有页面与交互；可参考调用方式，但不作为所有行为都已完善的保证 |
| [control_plane.py](../python/control_plane.py) | 签名控制命令、编码、命令通道 |
| [control_projection.zig](../src/runtime/control_projection.zig) | 分片投影的实际 JSON 字段 |
| [owner_session.py](../python/owner_session.py) | 登录、TOTP、会话期限与限速 |
| [release_lifecycle.py](../python/release_lifecycle.py) | 签名发布、策略包目录、生命周期 outbox |
| [strategy_instance.py](../python/strategy_instance.py) | 实例绑定、恢复、配置与代码切换、核心授权连接 |
| [strategy-package-release.md](strategy-package-release.md) | 签名策略包、运行依赖及实例合同的详细说明 |

UI 发起控制请求并展示结果；TradingShard 持有权威交易状态。发布策略包、进程健康、
实例 Ready、HTTP 请求成功均不等于获得交易权限。领域术语以 [GLOSSARY](../GLOSSARY.md) 为准；
Host 边界见 [ADR 0007](adr/0007-use-validated-pipes-for-strategy-host-data.md)，平台资格见
[ADR 0010](adr/0010-qualify-windows-and-linux-independently.md)。

## 2. 接口总表

“需要鉴权”均指同时提供 `owner_session` Cookie 和 `X-Owner-CSRF`，包括 GET。
请求体使用 JSON；页面接口返回 HTML，其他正常接口响应为 JSON。

| 方法 | 路径 | 鉴权 | 功能 |
|---|---|---|---|
| GET | `/`、`/index.html` | 否 | UI 页面 |
| POST | `/setup` | 否 | 首次设置口令并初始化 TOTP |
| POST | `/login` | 否 | 口令 + TOTP 登录 |
| POST | `/logout` | 是 | 注销当前会话 |
| GET | `/api/projection` | 是 | 分片状态、持仓、挂单及风险汇总 |
| GET | `/operator-records` | 是 | 操作审计记录 |
| GET | `/api/releases` | 是 | 发布、策略包目录和资格报告 |
| GET | `/api/strategy-instances` | 是 | 策略实例列表及状态 |
| POST | `/api/strategy-instances` | 是 | 创建、恢复、配置更新、代码替换及实例 ForwardRollback |
| POST | `/risk-warning` | 是 | 签发高危命令的一次性风险确认身份 |
| POST | `/command` | 是 | 交易控制命令，目标为分片或指定策略实例 |
| POST | `/lifecycle` | 是 | 发布、发布 ForwardRollback、凭证及节点切换请求 |

当前路由按 `self.path` 精确匹配；不要自行添加查询参数、末尾斜杠或路径前缀。
无版本前缀、分页、筛选、OpenAPI、WebSocket、SSE 或文件上传接口；
不能假定存在 `/health`、`/orders`、`/fills`、`/balances` 等路由。

## 3. 连接、认证与通用客户端

### 3.1 部署接线

`serve(app)` 绑定 `127.0.0.1`，端口为 `0`（由 OS 分配），返回 HTTP server 对象。
它不是固定端口的服务启动配置。部署方需要公布实际地址并负责进程与依赖组装。
默认 handler 不提供 TLS、CORS 或 OPTIONS 预检支持；优先使用同源 HTTPS 入口，
由反向代理转发到 loopback 后端，保留路径、Cookie 和 CSRF 请求头。
不要直接假定远端浏览器可以访问服务端的 `127.0.0.1`。

登录 Cookie 为 `owner_session`，带 `Path=/; HttpOnly; Secure; SameSite=Strict`。
正式浏览器对接应使用 HTTPS；本地 HTTP 的 Secure Cookie 行为须单独确认，
原始 HTTP 客户端验收通过不证明浏览器部署链已通过。

### 3.2 初始化与登录

首次初始化：

```json
{"passphrase":"<用户输入的口令>"}
```

提交至 `POST /setup`，成功返回 `{"ok":true,"totp_secret":"<base32>"}`。
口令至少 12 个字符，不满足时返回 400；重复初始化返回 409；
`totp_secret` 在不需要新建时也可能是 null。
TOTP secret 只用于引导用户录入认证器，不写入日志或通用前端存储。
现有 UI 没有调用此初始化接口；需要单独设计受控的首次安装流程。

登录请求 `POST /login`：

```json
{"passphrase":"<用户输入的口令>","code":"123456"}
```

成功返回 `{"ok":true,"session_token":"…","csrf_token":"…"}`，并设置 Cookie。
浏览器使用 HttpOnly Cookie，前端仅在会话内存中持有 CSRF token，不需要手工设置 Cookie。
TOTP 为 6 位字符串，保留前导零；步长 30 秒，允许相邻时间窗，已消费验证码拒绝重放。
默认连续失败 5 次限速 60 秒；错误凭证返回 401，限速返回 429。

当前只允许一个活动 OwnerSession，新登录会使旧 token 失效。默认会话有效期 900 秒，
每次通过鉴权的请求续期，因此持续轮询会续期。Web 重启后内存中的 CSRF 映射丢失；
页面刷新也会丢失当前 UI 内存中的 CSRF。Cookie 仍存在不代表可以继续请求，应重新登录。
`POST /logout` 请求体可用 `{}`；成功 `{"ok":true}`，后端撤销会话，但不主动清除浏览器 Cookie。

### 3.3 最小请求方式

```javascript
let csrf = ""; // 登录成功后赋值，刷新或认证失效后重新登录
async function request(method, path, body) {
  const headers = {"Content-Type": "application/json"};
  if (csrf) headers["X-Owner-CSRF"] = csrf;
  const response = await fetch(path, {
    method, headers, credentials: "same-origin",
    body: body === undefined ? undefined : JSON.stringify(body)
  });
  const data = await response.json();
  return {status: response.status, data};
}
```

这是请求示意；产品客户端还应处理网络中断、非 JSON 响应、请求超时和页面卸载。
跨源部署不能只修改 `credentials`，还需服务端与代理的 CORS、Cookie 策略支持，当前未提供。
不要把 Cookie、登录响应、TOTP、口令或完整认证请求写进遥测。

### 3.4 身份、数值和时间

| 数据 | 线上格式／注意事项 |
|---|---|
| `command_identity`、`warning_identity`、`target_identity`、栅栏 identity | UI 优先使用非零 128 位范围内的十进制字符串；不要转成 JS Number |
| 策略绑定中的 definition／strategy／portfolio／decision_domain identity | 非零、32 位小写十六进制字符串，无 `0x`；与控制命令身份格式不同 |
| `operation_identity` | 实例代码替换使用的非零 32 位小写十六进制字符串 |
| SHA-256 字段 | 64 位小写十六进制，来自实际字节；示例占位符不能直接提交 |
| `expected_version`、配置版本、数量、预算 | 整数；不同接口校验不同，不要把所有整数都无条件转字符串 |
| `expires_at`、`recorded_at` | Web 层 UTC Unix 秒；不是毫秒，也不是浏览器本地时间 |
| `*_micros` | 定点值，展示时按 10^6 换算并保留原值；不能混作所有资产的统一原子精度 |

当前投影和实例响应中部分 u64／金额／数量仍为 JSON number。
超过 `Number.MAX_SAFE_INTEGER` 时，普通 `response.json()` 会丢精度；后转 BigInt 无法恢复。
大数范围对接须使用保留原始整数的解析方案或先演进后端合同，不能宣称现有页面已全面解决。
`BigInt` 也不能直接交给 `JSON.stringify`。实例 `decision_domain` 转为控制目标时，
先按十六进制解析，再转十进制字符串，例如 `BigInt("0x" + decisionDomain).toString()`。

## 4. 只读接口及页面映射

### 4.1 GET /api/projection

成功外层为 `{"ok":true,"shards":[…]}`。每个正常分片的字段如下：

| 字段 | UI 用途 |
|---|---|
| `target_identity`、`source` | 控制目标十进制字符串；来源 journal 文件名 |
| `mode`、`status` | 运行模式与投影状态；按实际返回值展示，不从按钮点击推导 |
| `trading_authorized`、`effective_authority`、`may_reduce_only` | 授权事实、最终有效权限、是否仅减仓；分别展示 |
| `unresolved_latches`、`gates` | 锁存数量与安全栅栏；gate 有 `identity`、`kind`、`reason`、`open` |
| `open_orders` | 未完成订单数量，不是逐笔挂单数组 |
| `portfolio_position_quantity`、`exchange_position_quantity` | 组合与交易所仓位，不能合并为同一个含义 |
| `reconciliation_break` | 对账差异标志 |
| `last_sequence`、`operational_version` | 投影进度、控制操作乐观并发版本 |
| `mark_price_micros`、`open_cost_micros` | 标记价格与持仓成本 |
| `position_margin_requirement_micros`、`open_order_reservation_micros` | 持仓保证金要求与挂单预留 |

投影缺失时返回 503。单个 journal 解析失败可能仍返回 HTTP 200，且该元素只有
`degraded:true`、`reason` 及部分元数据；probe 进程失败还可能把文件名作为 `target_identity`。
必须先检查 `degraded`，再渲染正常字段；降级行不生成控制目标或交易按钮。

当前 ProjectionProvider 通过 Zig probe 重放 journal 生成视图，并非交易所实时行情订阅。
现有 UI 每秒轮询；新 UI 应避免重叠请求，展示最后成功获取时间、陈旧状态和失败原因。
`source` 或 `last_sequence` 不能单独证明数据实时。没有现金余额、逐笔成交、完整估值曲线接口；
不能把缺失值显示成 0，也不能用保证金占位推导冒充实际强平价格。

### 4.2 GET /operator-records

返回 `{"ok":true,"records":[…]}`，当前一次读取全部记录，无分页或服务端筛选。
普通控制记录含 `recorded_at`、`kind`、`command_identity`、`command_fingerprint`、
`target_identity`、`expected_version`、`risk_warning_identity`、`acknowledged`、`operator`。
生命周期记录还可含 `lifecycle_fingerprint`、`lifecycle_result`、`result`。
记录代表 Web 层操作轨迹，不能替代核心执行回执；记录缺失也不能直接证明请求未发生。
实例管理 POST 不走普通命令记录追加路径，不能用本接口作为完整的实例操作审计源。

### 4.3 GET /api/releases

返回 `ok`、`active_artifact`、`release_records`、`strategy_packages`、
`qualification_rejections`、`manifests`。其中 `manifests` 是服务端文件路径，不是下载 URL。
无发布管理器或读取失败返回 503。

策略包应展示 `definition_identity`、`package_manifest_sha256`、`release_artifact`、
`active_release`、校验结果与 `qualifications`；资格报告关联具体 `scope`，
状态为 `qualified`／`not_qualified`，不可折叠成不带范围的“生产可用”。
`qualification_rejections` 中保留清单路径与拒绝原因。包登记、active release、
资格通过和实例交易授权是不同状态，选择包时重新确认 `active_release`。

### 4.4 GET /api/strategy-instances

返回 `{"ok":true,"instances":[…]}`。实例有 `binding`、`status`、`reason`、
`trading_authorized`，以及按阶段出现的 `recovery`、`checkpoint`、`evidence`、`authority`、
`runtime_cursor`、`host_placement`、`config_transition`、`successor_transition`、`superseded_by` 等。
可选字段不能假定始终存在；Python 与原生实例的运行能力也不同。

| 状态／事实 | UI 行为 |
|---|---|
| `Ready` | 可提出显式启用；仍须满足核心追赶、版本与安全栅栏条件 |
| `Trading`、`trading_authorized` | 显示实际授权及 `authority`，提供停用操作 |
| `Recovering` | 显示 cursor／barrier 进度；保持查询，不自动启用 |
| `Stopped` | 展示原因；符合条件时提供恢复，不能以创建覆盖旧身份 |
| 配置／接替 transition 的 `unknown` | 展示结果不确定并要求核对核心版本，禁止盲目重试或恢复 |
| `host_placement`／`affected_instances` | 展示共享 Host、同 DecisionDomain 操作影响的实例范围 |

Web 重启不会仅凭磁盘上的 Ready 记录重建交易权限；需要实际 Host 与恢复证据。

## 5. POST /risk-warning 与交易控制

### 5.1 高危确认流程

1. 刷新投影，取目标的 `operational_version`；生成稳定的 `command_identity`。
2. 用完整待确认命令请求 `/risk-warning`。
3. 展示服务端的 `kind`、目标、`consequence` 和过期时间，由用户明确确认。
4. 原命令加入 `risk_warning_acknowledged:true`、`risk_warning_identity`。
   KillSwitch 还必须带回响应的 `referenced_latch_identity`。
5. 提交到 `/command` 或 `/lifecycle`；按实际业务结果显示，再查询状态。

RiskWarning 响应不带通用 `ok`，字段为 `warning_identity`、`kind`、`target_identity`、
`consequence`、`expires_at`，KillSwitch 另带 `referenced_latch_identity`。
默认有效期 300 秒，一次消费；过期或载荷不匹配返回 403，校验失败也会消费该确认。
Web 重启会清空未使用的确认；重新获取并让用户确认，不自动替用户确认。
低风险命令不调用此接口，也不能携带风险确认字段。

当前确认匹配检查 kind、目标、版本、目标仓位、栅栏引用及 target／manifest 路径／
expected_active／details／strategy_identity；不是对整个 JSON 的逐字段摘要确认。
特别是 `manifest_sha256` 不在该比较列表中。UI 必须冻结用户看到并批准的完整请求，
任何发布路径、摘要或操作内容改变后重新确认，不能宣称后端已对所有字段完整绑定。

### 5.2 POST /command 字段

| 字段 | 要求 |
|---|---|
| `kind` | 使用下表的交易命令 |
| `target_identity` | 分片／实例所属核心目标，十进制字符串 |
| `expected_version` | 最近投影的 `operational_version`，整数 |
| `command_identity` | UI 应提供稳定非零身份；省略虽会自动生成，但响应不返还生成值，不利于重试 |
| `expires_at` | 可选 UTC 秒；省略时首次生成 now + 300，当前工作区修复会在相同命令重试时复用 |
| `target_position` | DeRisk 目标敞口；当前 UI 的 DeRisk→0 通过省略使用默认零 |
| `referenced_latch_identity` | KillSwitch 使用 warning 返回值；ResolveLatch 使用待解除 gate 的实际 identity |
| `risk_warning_acknowledged`、`risk_warning_identity` | 高危命令必需 |
| `strategy_identity` | 可选，32 位十六进制；指定时走策略实例控制路径 |

| kind | 高危 | 作用 | 可指定 strategy_identity |
|---|---|---|---|
| `enable_trading` | 是 | 提出新增风险授权 | 是 |
| `trading_pause` | 否 | 暂停并撤单，不自动平仓 | 是 |
| `cancel_open_orders` | 否 | 撤销当前挂单 | 否 |
| `stop_keep_positions` | 是 | 停止并保留仓位 | 是 |
| `de_risk` | 是 | Reduce-only 降至目标敞口，完成前可处于 Draining | 否 |
| `resolve_latch` | 是 | 解除指定安全原因；不会自动重新授权 | 否 |
| `kill_switch` | 是 | 禁止新增风险并撤单，不自动平仓 | 是 |

底层 codec 中虽有 `start_recovery`，当前 Web `/command` 不接受它。
发布、凭证和 failover 必须走 `/lifecycle`，不能因其名字出现在提示文案中就提交给 `/command`。
指定实例但实例后端未接入或命令不支持时，当前返回 400 `strategy instance command unavailable`。

低风险请求示例：

```json
{"kind":"trading_pause","target_identity":"1","expected_version":3,"command_identity":"9001"}
```

普通分片命令成功返回 `{"ok":true,"queued":"trading_pause"}`，仅代表签名入队。
通过投影确认最终 mode、权限及版本；版本变化也可能来自其他操作，不能作为独立的逐命令回执。
实例命令返回 `{"ok":true,"result":{…实例记录…}}`；查看 status、authority 和拒绝原因，
不能只判断 HTTP 200 或外层 ok。实例启用依赖节点私有 NativeAuthority 及实际 HostActivated 屏障。

相同身份和相同内容返回缓存结果，不再次入队；修改内容返回 409。
字符串／数字类型变化也可能改变指纹，重试保留原始字段和值。
超时后不能换一个新身份盲目重发，也不能把默认截止时间复用理解成延长命令有效期。

## 6. POST /lifecycle

所有生命周期操作均要求接入 `release_manager` 和 `lifecycle_outbox`，即使本次只做发布。
缺失返回 503。`command_identity` 必填；目标既有 `target_identity`（风险提示用），
又有 `target`（outbox 用），UI 应明确设置，避免省略 target 后落到 `global`。

| kind | 高危 | 请求补充字段 | 当前处理 |
|---|---|---|---|
| `deploy_release` | 是 | `manifest_path`、`expected_active`、策略包发布的 `manifest_sha256` | 校验并尝试激活签名发布 |
| `forward_rollback` | 是 | 同上 | 正向发布指定旧版本，不回退经济历史 |
| `credential_stage` | 否 | `target`、`details` | 写签名 outbox |
| `credential_activate` | 是 | `target`、`details` | 写签名 outbox |
| `credential_retire` | 否 | `target`、`details` | 写签名 outbox |
| `credential_revoke` | 是 | `target`、`details` | 写签名 outbox |
| `credential_rotate` | 否 | `target`、`details`；现有 UI 使用 `{"version":2}` | 写签名 outbox |
| `failover` | 是 | `target`、`details` | 写签名 outbox，不能据此宣称节点已接管 |

`details` 为交给消费方的对象，本 HTTP 层没有完整定义各消费方的业务 schema。
不要自行假设只填 version 就能完成全部凭证生命周期；不能在其中传口令、密钥等秘密材料。

发布确认前的基础请求示例：

```json
{"kind":"deploy_release","command_identity":"9101","target_identity":"1","target":"1","manifest_path":"D:/approved/release.json","manifest_sha256":"<已批准清单的64位摘要>","expected_active":"release-a"}
```

路径指服务端受信目录中的已批准 manifest；不是用户电脑本地路径或上传接口。
首次发布 `expected_active` 为 null；已有发布须绑定实际 active artifact。
确认后加入 RiskWarning 字段再提交；策略包应固定清单摘要，旧单二进制发布的兼容规则见发布合同。

发布响应外层：`{"ok":true,"kind":"deploy_release","result":{…}}`。
`result.status` 为 `activated`、`rejected` 或 `unknown`，后两者也可能返回 HTTP 200。
`unknown` 必须显示结果不确定并查询当前发布，不能显示成功或自动回滚。

凭证／failover 响应的 result **不是**统一状态对象，而是：

```json
{"ok":true,"kind":"credential_rotate","result":{"payload":{"command_identity":9102,"kind":"credential_rotate","target":"1","details":{"version":2}},"signature":"…"}}
```

其中没有 `result.status="queued"`。当前现有 UI 仅接受 `activated`／`queued` 的通用判断
不适用于该信封，应单独展示“请求已写入签名 outbox，等待消费方执行”。
没有 outbox 执行状态查询 HTTP 接口，不能编造完成进度或成功回执。
同一命令身份内容冲突返回 409；重试须保留原载荷和确认字段。

## 7. POST /api/strategy-instances

此接口同时处理多个操作；创建没有 `operation` 字段，其他操作的字段集合必须精确匹配。
不要把创建表单的所有字段原样塞进 recover／update_config／replace 请求。
调用可持续较长时间，等待时并行 GET 查询进度；前端取消等待不代表后端撤销执行。

### 7.1 创建并预热

必须恰好包含以下字段，不能额外添加 `operation:"create"`：

```json
{
  "release_artifact":"approved-release",
  "definition_identity":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  "package_manifest_sha256":"<64位小写十六进制>",
  "strategy_identity":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
  "portfolio_identity":"cccccccccccccccccccccccccccccccc",
  "decision_domain":"dddddddddddddddddddddddddddddddd",
  "config_version":1,
  "config_json":"{\"warmup_events\":1}",
  "config_sha256":"<config_json实际ASCII字节的SHA-256>",
  "scopes":[{"venue":"okx","exchange_account":"eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee","instrument":"ffffffffffffffffffffffffffffffff"}],
  "risk_budget":100,
  "initialization":"new"
}
```

这是字段格式示意，不是可直接运行的交易配置。绑定必须匹配部署方批准的 DecisionDomain、
VirtualPortfolio、账户品种范围及整数预算；HTTP 不能创建节点归属或批准额度。
当前 scopes 验证仅接受 `okx`／`binance`／`bybit`，不能因为其他 Venue adapter 已存在就自行加入。
scopes 必须按 `(venue, exchange_account, instrument)` 排序去重，数量 1–256。

`config_json` 是嵌套的规范 JSON **字符串**，不是普通对象：ASCII、无多余空白、键排序、
禁止浮点及重复键；摘要按最终传输的字符串字节计算，不能先算摘要再格式化。
配置还必须满足签名策略定义自己的 schema。完整 binding 的规范编码上限为 64 KiB。
版本和预算按后端整数合同校验，不能从 UI 任意指定越过批准范围。

成功返回 `{"ok":true,"result":{…,"status":"Ready","trading_authorized":false}}`。
运行加载失败也可能返回 HTTP 200、`ok:false`、`result.status:"Stopped"` 及 reason；
字段验证等异常返回 400。相同实例身份与完全相同 binding 返回已有记录；
旧身份内容变化拒绝，不能借新建绕过恢复或配置切换。

### 7.2 恢复

```json
{"operation":"recover","strategy_identity":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}
```

只能使用现有不可变 binding 与已提交 checkpoint，缺失或损坏不会退回空状态初始化。
需要先停止现有 Host。恢复成功到 Ready，仍无交易授权；GET 可显示 Recovering 和进度。
处于未知配置／接替切换状态时，先核对核心版本。

### 7.3 更新配置

```json
{"operation":"update_config","strategy_identity":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","expected_config_version":1,"config_version":2,"config_json":"{\"warmup_events\":2}","config_sha256":"<实际字节摘要>","transition":"Keep"}
```

仅支持 `Keep`、`Rebuild`，不支持 `Migrate`；新版本必须满足后端版本和内容约束。
操作可能排空整个 DecisionDomain，先显示受影响实例。查看
`result.config_transition.status == "completed"`，成功后 Ready，需显式重新启用。
当前 `native_static` 定义不支持此参数切换路径，不应对所有实例都启用相同按钮。

### 7.4 替换代码与实例 ForwardRollback

```json
{"operation":"replace","strategy_identity":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","expected_definition_identity":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","release_artifact":"approved-release-b","definition_identity":"11111111111111111111111111111111","package_manifest_sha256":"<新包摘要>","operation_identity":"22222222222222222222222222222222"}
```

`operation` 可改为 `forward_rollback`，字段集合相同。
先通过 `/lifecycle` 安装目标签名发布，再请求实例切换。要求旧实例 Ready／Trading、
当前定义匹配、新定义不同、旧责任闭合和节点权威可用。
ForwardRollback 还要求目标是同一 VirtualPortfolio 曾使用的定义内容。

创建新的 StrategySuccessor 身份，使用 Rebuild，延续原 VirtualPortfolio 经济历史；
不能把新代码直接覆盖到旧实例身份。`operation_identity` 是此切换的稳定重试身份，
与 `/command` 的十进制 command_identity 不同。
查看 `result.successor_transition.status`、`to_instance` 和旧实例 `superseded_by`；
完成状态为 `completed`，接替实例 Ready 后仍需显式启用。整个 DecisionDomain 可能受影响。

## 8. 后端依赖、错误和页面行为

### 8.1 “后端未配置”含义

| 依赖 | 控制能力 | 缺失时 |
|---|---|---|
| `ui_path` | 页面 HTML | 页面返回 404 |
| `projection_provider` | 分片只读视图 | `/api/projection` 返回 503 |
| `release_manager` | 发布、包目录 | `/api/releases` 返回 503 |
| `release_manager` + `lifecycle_outbox` | 发布和生命周期操作 | `/lifecycle` 返回 503 |
| `release_manager` + `instance_source` | 创建 InstanceManager，实例查询／管理 | `/api/strategy-instances` 返回 503 |
| source 的节点权威连接、实际输入与部署归属 | 核心授权、追赶及切换 | 按操作返回拒绝或失败状态，不能保证统一为 503 |

这些是后端启动时注入的对象，不是“用户尚未创建策略”。UI 不通过 HTTP 配置它们。
没有单独 capability discovery 接口，UI 根据对应接口结果显示“能力未接入”，
不要把 503 当作空列表，或引导用户通过反复创建策略解决。

### 8.2 错误处理表

| 结果 | 含义与建议 |
|---|---|
| 200 | 检查 body：可能只是入队、拒绝、未知、Stopped 或单行投影降级 |
| 400 | 参数、操作类型或后端业务校验失败；展示 error，不自动重试 |
| 401 | 未登录、过期或会话被撤销；停止受保护请求，重新登录 |
| 403 | CSRF 或风险确认失败；区分具体 error，重新登录或重新确认 |
| 404 | 路由不存在或 UI 未部署；检查路径和部署配置 |
| 409 | 初始化重复、命令身份／内容冲突等；核对现有状态，不换身份硬重发 |
| 429 | 登录限速；等待冷却，当前无 Retry-After 合同 |
| 503 | 后端依赖缺失或数据读取失败；展示不可用，不当作零值 |
| 网络错误／超时／非 JSON | 执行结果可能不确定；查询现有状态，避免重复副作用 |

错误响应通常为 `{"ok":false,"error":"…"}`，但当前并非所有内部异常都有统一 JSON 捕获。
前端必须容忍代理错误页、连接关闭和无效 JSON，不能将解析失败显示为操作成功。

## 9. 建议的页面与交互顺序

| 页面 | 数据和操作 |
|---|---|
| 初始化／登录 | `/setup` 独立引导；`/login` 后保存内存 CSRF；退出调用 `/logout` |
| 总览 | `/api/projection`；显示权限、栅栏、对账与更新时间 |
| 持仓挂单 | 同一投影的组合／交易所仓位和挂单数量；明确为汇总 |
| 风险与保证金 | gates、预留、保证金要求；降级／陈旧时禁用依赖这些状态的操作 |
| 盈亏 | 仅展示已有成本／标记字段；缺失现金、估值、曲线明确标注不可用 |
| 发布与策略包 | `/api/releases`；发布前确认 artifact、摘要、当前 active 和资格范围 |
| 策略实例 | 实例 GET／POST；按实际状态与运行类型显示恢复、配置、接替、启停 |
| 操作台 | `/risk-warning` → `/command` 或 `/lifecycle`；显示目标、范围、前置版本与结果 |
| 命令历史 | `/operator-records`；区分请求记录和权威执行事实，不伪造逐命令完成状态 |

普通操作建议过程：刷新状态 → 构造固定请求 → 如需则风险确认 → 提交 → 显示受理结果 → 查询实际状态。
按钮等待期间防止重复点击，保留稳定请求身份；查询到 Ready 不自动串联 EnableTrading。
对账异常、锁存未解除、投影降级、发布结果 unknown 等情况应保留明确原因。
动态名称、reason、路径和 JSON 内容用 textContent 或转义后渲染，不能直接作为 HTML。

## 10. 对接完成检查与当前范围

- 登录 Cookie、CSRF、刷新后重新登录、Web 重启及单会话失效均在真实浏览器中检查。
- 每个精确路由、200 业务失败、401／403／409／429／503 和非 JSON 响应都有明确展示。
- 大数、UTC 秒、micros、十六进制实例身份与十进制控制身份不混用。
- 高危确认一次性消费，KillSwitch 引用正确；ResolveLatch 后仍需显式启用。
- 重试保留请求身份与载荷；入队、outbox 写入、Ready、activated 和交易授权分别展示。
- 投影 degraded／陈旧、长操作、共享 Host 与 DecisionDomain 影响范围均可见。
- 发布摘要和配置摘要来自实际批准字节；请求不传入账户秘密、任意事件帧或核心权威配置。

现有可复用检查入口：

```text
python python/verify_control_plane_release.py
python python/verify_release_lifecycle.py
python python/verify_control_plane.py
python python/verify_control_plane_wave.py
python python/verify_operator_ui.py
node tools/verify-strategy-package-ui.cjs
python -m unittest discover -s python -p test_strategy_package_release.py
python -m unittest discover -s python -p test_owner_session_security.py
```

这些程序使用离线／合成夹具，部分会编译 Zig 并重写 `.scratch/` 下验收目录；
不要指向运行服务的存储。Zig 应使用仓库固定版本，构建入口遵守 `tools/zig-entry.py`。
实例运行的专项检查与平台依赖见 [策略包发布文档](strategy-package-release.md)。
HTTP 客户端或 VM DOM 检查不能替代实际浏览器、HTTPS／代理、目标节点接线和平台验收；
本文不宣称这些部署检查已完成，也不以离线通过替代 Demo／生产资格。

## 11. 使用 RingwinUi 作为独立前端

### 11.1 工程定位与当前状态

采用 `D:\github\RingwinUi` 作为独立前端工程，复用
`D:\github\Ringwin-control-plane` 的 Python 控制面后端。
前端保留自己的源码、依赖和构建流程，通过本文的 HTTP 合同接入后端。
现有 `python/operator_ui.html` 可作为交互参考，不需要把 React 源码嵌入该文件。

2026-11-05 源码检查时，RingwinUi 的状态如下；后续修改后应重新核对：

| 项目 | 已有内容与待办 |
|---|---|
| 技术栈 | React、TypeScript、Vite、Astryx、StyleX、Recharts；可复用现有导航、主题、布局和表格 |
| `src/App.tsx` | `ControlPanelDemo` 为静态演示，控制按钮禁用，尚未调用控制面 API |
| `src/scanner/CrossExchangeScanner.tsx` | 机会列表、事件分布及汇总使用硬编码样例 |
| 资金费率／做市页面 | `FundingRateScanner` 和 `MarketMakingScanner` 当前复用 `PerformanceScanner` 样例绩效页面 |
| `vite.config.ts` | 开发端口 5173、strictPort；尚未配置控制面代理 |
| 版本管理 | 目录当时没有 Git 仓库；正式修改前建议纳入版本管理并保留当前版本 |
| 已做检查 | `npm.cmd run typecheck` 通过；未验证构建、浏览器及真实前后端联通 |

修改 UI 时先读取该工程的 `AGENTS.md`，按 Astryx 的发现流程查组件和布局，
复用既有组件、主题与 tokens。本文不替代前端工程自己的布局和样式约束。

### 11.2 分阶段接入顺序

| 阶段 | 工作 | 完成标准 |
|---|---|---|
| 1. 认证与请求 | 新增登录页、统一请求函数、内存 CSRF、会话失效和错误处理 | 登录后可访问受保护接口，刷新／重启／单会话失效行为明确 |
| 2. 真实只读控制面 | 用投影、操作历史、发布和实例查询替换控制面演示数据 | 展示真实来源、更新时间、空态、不可用及 degraded，不混用样例值 |
| 3. 交易控制 | 接暂停、撤单、高危确认、KillSwitch、启用及其他支持的控制命令 | 按“确认→提交→查询实际状态”交互；权限和版本来自后端 |
| 4. 策略生命周期 | 包选择、实例创建／恢复、配置更新、版本接替及发布操作 | 区分包登记、Ready、发布激活和核心交易授权；明确受影响范围 |
| 5. 扫描与绩效数据 | 明确真实数据源和后端读取合同，再替换扫描／资金费率／绩效样例 | 每项指标有实际来源、单位、时间范围及陈旧状态 |

优先交付“登录 + 真实只读控制面”，完成浏览器联通后再开放写操作。
请求处理和认证逻辑集中复用，不在每个页面各写一套 Cookie／CSRF／错误处理。
沿用已有技术栈，具体文件拆分按前端工程的现有组织方式决定。

第 5 阶段需要额外的数据读取能力。当前控制面接口不能直接提供下列页面的全部数据：

| 页面指标 | 当前缺口 |
|---|---|
| 跨所机会扫描 | 共同市场、可执行价差／规模、机会事件次数、持续时间分布及行情新鲜度 |
| 资金费率 | 各 Venue 的费率、结算周期、历史及净收益估算 |
| 绩效 | 收益曲线、完整已实现／未实现盈亏、回撤、胜率和 Sharpe 等统计 |

先核对仓库已有研究／扫描模块的输出，再确定如何只读提供给 UI；
模块或结果文件存在不等于已有 HTTP 接口。不能把 `/api/projection` 的分片汇总
解释为这些指标的数据源。接通前保留明确的“演示”标签或显示“数据未接入”，
不要混合真实状态与样例收益，也不要在浏览器接入交易所私钥来填补后端缺口。

### 11.3 开发与正式部署

推荐同源入口：

```text
浏览器 → HTTPS 入口
          ├─ 页面、静态资源 → RingwinUi/dist
          └─ 控制面接口     → Python loopback 服务
```

开发时在 Vite 中代理本文列出的控制面接口路径到后端的实际地址；
`/api/*` 之外还包括 `/setup`、`/login`、`/logout`、`/risk-warning`、`/command`、
`/lifecycle`、`/operator-records`。页面根路径和前端静态资源由 Vite 提供，
不能把全部路径都代理给 Python。后端当前使用动态端口，开发组装需明确传递实际目标地址。
代理只解决同源转发，不自动解决 Secure Cookie；按第 3 节验证浏览器 HTTPS 链路。

正式部署构建 RingwinUi，由静态服务器／反向代理提供 `dist` 内的 HTML、JS、CSS，
并保留控制面接口的原路径、Cookie 与 CSRF 请求头。控制面路径优先于 SPA 回退规则，
否则 API 错误可能被前端 index.html 掩盖。若后续引入浏览器路径路由，再为页面配置 SPA 回退。
Vite dev server 和 preview 不作为正式服务部署方案。

仅将 Python 的 `ui_path` 指向 Vite 构建后的 `index.html` **不足以部署 React UI**：
当前 handler 仅返回单个页面，不负责提供构建后的 JS／CSS 资源。
采用外部静态服务时，由它处理 `/` 和 `/index.html`，控制面后端继续负责接口。

### 11.4 前端验收与交付边界

前端改动后运行 `npm.cmd run typecheck` 和 `npm.cmd run build`，再按第 10 节
完成真实浏览器检查。Windows PowerShell 若阻止未签名的 `npm.ps1`，可直接使用
`npm.cmd`，无需为运行检查改变系统执行策略。

至少验证登录、CSRF、Cookie、只读轮询、降级／陈旧展示、稳定身份重试和一次性高危确认；
写操作使用隔离的离线验收环境。新前端通过类型检查或构建不代表后端能力已接入，
已有后端验收也不自动证明新 React UI 的 Cookie、代理、渲染及交互正确。
本文仅记录接入建议；尚未为 RingwinUi 实施上述修改或完成浏览器联调。
