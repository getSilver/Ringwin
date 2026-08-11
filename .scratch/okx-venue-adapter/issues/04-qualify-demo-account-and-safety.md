# 资格化 Demo 账户与实盘式安全栅栏

Type: task
Status: resolved
Assignee:
Blocked by: 01, 03
Parent: [产品化接入 OKX Venue Adapter](../map.md)

## Question

如何在不记录凭证的前提下验证目标 OKX Demo API Key 的环境、读取/交易权限、无提现权限、账户模式、持仓模式、逐仓配置、Instrument 白名单和初始无未解释风险状态，并把 `--demo-live`、名义金额上限、前置对账、撤单及 Reduce-only 清仓固化为不可绕过的验收栅栏？

## Progress

- 2026-08-11：项目根目录 `.env.local` 已确认被 Git 忽略，五个配置键均为非空；Windows ACL 已在本机收紧为当前用户、SYSTEM 与 Administrators，检查过程未输出凭证值。
- 新增只读 [`tools/okx-demo-preflight.ps1`](../../../tools/okx-demo-preflight.ps1)：固定 Demo header、`BTC-USDT`/`BTC-USDT-SWAP` 白名单和 25 USDT 单笔名义上限；验证时钟、权限、Futures/net 模式、逐仓杠杆配置、账户可交易 Instrument、零仓位、零挂单、零负债，全程不执行写请求。
- 首次实测公开时间成功，但 Demo `GET /api/v5/account/config` 返回 `50101 APIKey does not match current environment`；预检立即失败关闭，未继续私有查询且未执行任何交易动作。资格保持 open，等待换用与配置 entity/REST host 匹配的 **Demo Trading API Key** 后复测。
- 更换 Demo Key 后复测：Demo 环境鉴权、Read + Trade 且无 Withdraw 权限、Futures account mode 均通过；目标账户当前为双向 `long_short_mode`，不满足既定单向 `net_mode`，预检在此失败关闭且未修改账户。待 SystemOwner 在 OKX Demo Trading UI 切换为单向持仓后继续逐仓、Instrument 与零风险状态检查。

## Answer

### 资格结果

2026-08-11 在 Windows Demo 节点运行只读预检并通过：`entity=global`、REST host 为 `openapi.okx.com`、所有私有请求固定携带 `x-simulated-trading: 1`；Key 只有 `read_only,trade` 且无 Withdraw；账户为 Futures mode (`acctLv=2`) 与单向净持仓 (`posMode=net_mode`)；`BTC-USDT-SWAP` 存在 isolated/net leverage 配置；账户私有 Instrument 中 `BTC-USDT` 与 `BTC-USDT-SWAP` 均可用。

启动事实为零非零仓位、零普通挂单、零 `conditional/oco/trigger/move_order_stop/iceberg/twap/chase` 策略单及零负债；只观察到 USDT 为非零资金币种，不记录金额。凭证、UID、余额金额、签名和认证 header 均未进入票据、日志或 Git。观测到 `ctIsoMode=automatic` 只按 OKX Auto transfers 原义保存，不能据此宣称存在或关闭自动追加保证金，因此本结果只资格化 Demo 功能波次，不构成生产资格。

### 不可绕过的验收栅栏

- 凭证只允许来自被 Git 忽略且限制本机 ACL 的 `.env.local`/后续 credential provider；不得来自命令行、源码或可持久化日志。endpoint 必须是显式 entity profile 下的 HTTPS OKX origin。
- 构建和运行配置均固定 `environment=demo` 与 simulated header；首波实现不提供 production 分支。会成交的验收还必须显式传入 `--demo-live`，缺少任一条件均不得建立 OrderEntryReady。
- 每次 `--demo-live` 前必须重新完成时间、权限、账户/持仓模式、isolated leverage、私有 Instrument、普通/策略挂单、仓位、负债及 REST/WS 对账；任何缺失、漂移、Unknown 或非白名单事实均失败关闭。
- 唯一白名单为 `BTC-USDT` 和 `BTC-USDT-SWAP`。每笔订单及整个账户由执行网关同时执行 **25 USDT** 名义硬上限；batch 逐项检查且不能借拆单越过账户上限。Market 仍须受价格保护，不因名义上限而成为无界订单。
- 普通新增风险只有在全部 gate 为真时可发送；Cancel、Reconciliation 与 `BTC-USDT-SWAP` 的 VenueReduceOnly 清仓保留独立容量。任何可能已发送但结果不明的写请求先进入 Unknown 并 REST 对账，禁止自动重放。
- 验收结束先停止新增风险并对账，再精确撤销本次运行的活动订单；SWAP 残余仓位只能用 `reduceOnly=true`、方向与数量受当前权威仓位约束的订单清零。SPOT 必须恢复到启动库存；若无法证明，保留事实并锁存失败，不盲目卖出。最终再次证明零挂单、零策略单、零仓位/无库存差异及零 Unknown，才能宣告清理完成。

[`tools/okx-demo-preflight.ps1`](../../../tools/okx-demo-preflight.ps1) 是当前 Windows 只读资格入口。25 USDT、`--demo-live`、发送前对账和清理规则仍须由后续 Zig Adapter/Execution Gateway 代码再次强制，不能只依赖运维脚本。
