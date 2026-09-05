# 08: 使 Testnet 资格证据不可自行声明

Type: task
Status: resolved
Assignee:
Blocked by: [06](06-route-binance-through-gateway.md), [07](07-route-bybit-through-gateway.md)
Parent: [修复交易核心权威接缝与验收完整性](../map.md)

## Question

如何区分 ContractTested、OfficialConfirmed 和 TestnetQualified，使调用者不能通过构造全 true 布尔值、
前后状态或任意相等摘要自行授予资格？

## What to build

让每一级 Venue 证据由对应执行入口产生并携带可验证来源。离线合约测试只能证明 ContractTested；
官方资料确认只能证明 OfficialConfirmed；OKX DemoQualified 必须来自 OKX Demo 的显式 opt-in runner；
TestnetQualified 必须来自目标 Testnet 的显式 opt-in runner，完成真实请求、私有事实、reconciliation
和隔离轨迹。没有对应环境记录时，聚合结果必须诚实停在较低等级。

## Blocked by

- [06: 让 Binance 通过统一 Gateway 完成端到端路径](06-route-binance-through-gateway.md)
- [07: 让 Bybit 通过统一 Gateway 完成端到端路径](07-route-bybit-through-gateway.md)

## Acceptance

- [x] 公共 API 不再接受可由调用者任意构造的“全部通过”布尔矩阵来生成 TestnetQualified。
- [x] ContractTested、OfficialConfirmed、TestnetRun/TestnetQualified 具有互不冒充的证据类型和明确聚合规则。
- [x] Testnet runner 默认不运行，只有 SystemOwner 显式授权且所需外部输入完整时才访问网络。
- [x] 缺少真实运行、部分失败或隔离失败时保存失败证据并返回非 qualified，不生成成功替代摘要。
- [x] 离线自动测试证明伪造状态、任意 digest、重放旧 run 和跨 Venue 复用证据均被拒绝。
- [x] OKX Demo 只能映射为 DemoQualified；不能升级、复用或伪装为任一 Venue 的 TestnetQualified。
- [x] 当前状态输出在未执行真实 Testnet 时明确显示“未运行”，且不要求任何生产账户、资金或密钥。

## Evidence

- Removed the public `recordTestnetRun`/`grant` path that accepted caller-provided counters, booleans and
  equal digests. Binance and Bybit now expose distinct sealed qualification types with no synthetic constructor.
- The checked-in aggregate reports OKX Demo, Binance Testnet and Bybit Testnet as `not_run`; it cannot accept
  fabricated run records. The existing OKX executable emits `demo_qualified` only after its explicit live path,
  cleanup and replay checks succeed.
- Venue-local ledgers retain failure reasons and reject zero, duplicate and regressing run ids. Offline tests
  assert the promotion APIs are absent, stale evidence is rejected and Venue qualification types are distinct.
- No Binance/Bybit live Testnet runner or external run record exists in this repository; therefore no
  `TestnetQualified` value is produced. Adding such a runner requires explicit owner authorization and complete
  Testnet inputs, and remains outside the default offline entrypoint.
