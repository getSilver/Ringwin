# 资格化 Demo 账户与实盘式安全栅栏

Type: task
Status: open
Assignee: Codex
Blocked by: 01, 03
Parent: [产品化接入 OKX Venue Adapter](../map.md)

## Question

如何在不记录凭证的前提下验证目标 OKX Demo API Key 的环境、读取/交易权限、无提现权限、账户模式、持仓模式、逐仓配置、Instrument 白名单和初始无未解释风险状态，并把 `--demo-live`、名义金额上限、前置对账、撤单及 Reduce-only 清仓固化为不可绕过的验收栅栏？

## Progress

- 2026-08-11：项目根目录 `.env.local` 已确认被 Git 忽略，五个配置键均为非空；Windows ACL 已在本机收紧为当前用户、SYSTEM 与 Administrators，检查过程未输出凭证值。
- 新增只读 [`tools/okx-demo-preflight.ps1`](../../../tools/okx-demo-preflight.ps1)：固定 Demo header、`BTC-USDT`/`BTC-USDT-SWAP` 白名单和 25 USDT 单笔名义上限；验证时钟、权限、Futures/net 模式、逐仓杠杆配置、账户可交易 Instrument、零仓位、零挂单、零负债，全程不执行写请求。
- 首次实测公开时间成功，但 Demo `GET /api/v5/account/config` 返回 `50101 APIKey does not match current environment`；预检立即失败关闭，未继续私有查询且未执行任何交易动作。资格保持 open，等待换用与配置 entity/REST host 匹配的 **Demo Trading API Key** 后复测。
