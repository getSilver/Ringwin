# 2026-11-04 源码审阅证据

## Evidence boundary

- 审阅基线：`d973030794cc78c0abc5ccd939dcc0ecabf30e98`；本次规格发布前再次核对 HEAD 一致。
- 工具链：Zig `0.17.0-dev.315+5b647b792`，Windows 离线探针。
- 索引涉及 src 下 176 个 Zig 文件、106,181 行，包含测试和验收；不表示逐行审计全部源码或穷尽漏洞。
- 以下测试结果来自上一轮审阅，不是本轮文档发布时重新执行的测试。
- 审阅在忽略目录的冻结源码副本中追加探针；原实现保持不变。当前文档任务不再修改探针、不编译、不运行测试。
- 临时探针不是正式回归，后续修复须沿公开 seam 转入现有正式测试组织。
- 未测试真实账户、凭证、网络交易、目标 Linux 断电、完整负载、完整密码学及真实挂起 Host。

## Findings and routes

| 发现 | 当前源码定位（行号绑定上述 revision） | 证据与结论 | 承接规格 |
|---|---|---|---|
| F1 错误成交方向 | [TradingShard](../../src/trading/trading_shard.zig)，4390–4405、4451–4454 | 公共 apply 接受买单的 sell Fill，仓位 -100；相同 buy Fill 基线 +100 | [01](issues/01-fill-order-side.md) |
| F2 Amend 授权与额度 | [Binance](../../src/adapters/binance/binance_venue_adapter.zig)，278–295、312–323；[Bybit](../../src/adapters/bybit/bybit_venue_adapter.zig)，241–255、269–278 | explicit_enable=false、上限=1、合法订单引用的 amend，两个 transport 都调用 1 次 | [02](issues/02-amend-admission.md) |
| F3 最终发送期限 | 同上 Binance 268、335–339；Bybit 230、289–294 | 签名器把时钟从 1 推进至 11，超过原 deadline，两家仍提交 | [03](issues/03-final-dispatch-deadline.md) |
| F4 返佣金额表示 | [Hyperliquid](../../src/adapters/hyperliquid/hyperliquid_venue_adapter.zig)，1132、1895–1898；TradingShard 4406 | 旧 adapter 测试要求 fee=null；相同 null fee / 正 rebate 形状进入公共核心返回 MissingFillFee | [04](issues/04-hyperliquid-rebate-fill.md) |
| F5 物理尾部隐藏 | [DurableStore](../../src/persistence/durable_store.zig)，1107–1112、1686–1700；[Owner](../../src/runtime/demo/demo_authority.zig)，517–532 | manifest root_publish 故障后磁盘有 seq=3，但重开报告 last=committed=2，尾隔离条件看不到真实高水位 | [05](issues/05-physical-recovery-suffix.md) |

F2 上一轮使用“授权关闭且金额超限”的组合反例；单独超限、单独禁用及其他权限条件尚须在正式回归中分别覆盖。
F4 已证实 producer 输出与 consumer 合同不兼容，但上一轮核心探针使用同形 canonical Fill，未将实际 Hyperliquid 输出连入核心；04 明确要求补真实跨 seam 验收。
F5 已证实 Store 隐藏物理尾；Owner.closed 的影响由当前调用路径确认，上一轮未运行完整 Owner 恢复反例。05 必须补此验收，不能将 Store 探针冒充全链路证明。

## Reproduction observations

| 场景 | 期望安全行为 | 上轮观察 |
|---|---|---|
| 买单收到 sell Fill | 应拒绝且经济投影不变 | apply 成功，position=-100 |
| 买单收到 buy Fill（正向基线） | 正常入账 | 通过，position=100 |
| Binance amend，禁用且超限 | transport.calls=0 | expected 0, found 1 |
| Bybit amend，禁用且超限 | transport.calls=0 | expected 0, found 1 |
| Binance 签名后 now=11、deadline=10 | transport.calls=0 | expected 0, found 1 |
| Bybit 签名后 now=11、deadline=2 | transport.calls=0 | expected 0, found 1 |
| fee=null、rebate=147000 的 canonical Fill | 生产者声称的合法返佣应能入账 | MissingFillFee；核心拒绝符合其缺失金额合同，需改生产者表示 |
| seq=2 已提交，seq=3 segment 发布后 manifest 失败 | 保留物理 last_sequence=3，提交 barrier=2 | 物理 210 bytes；可见 137 bytes；last=2、committed=2 |

七个反例场景对应五类问题；不是七次已证明的真实交易损失。
F5 不证明已提交经济事实丢失，不应与 R1 的耐久性风险混为一谈。

### 原始日志

- [Binance 反例](../build/architecture-review-20261104/binance-audit-result.txt)：两个预期安全断言失败；另有入口/过滤匹配的既有测试。
- [Bybit 反例](../build/architecture-review-20261104/bybit-audit-result.txt)：两项发送反例；因导入依赖，同次还运行了 Store 反例，不重复计数。
- [核心正反例](../build/architecture-review-20261104/core-audit-result.txt)：正确方向基线通过，错误方向及返佣形状断言失败。
- [Store 独立反例](../build/architecture-review-20261104/store-audit-result.txt)：物理尾高水位断言失败。
- [审阅元数据](../build/architecture-review-20261104/audit-metadata.json)：记录冻结基线和四个只追加探针的副本文件。

首次默认测试栈在 fixture 应用处溢出；之后使用仓库已有的大栈测试口径取得上述业务结果。
初次 stack overflow 不作为 F1–F5 的业务证据，也不能独立证明生产性能不足。

### 上轮命令形态

下列命令为历史复现说明，本轮文档任务未运行：

```text
zig test --stack 536870912 --test-filter archreview --dep entry_options
  -Mroot=<repo>/.scratch/build/architecture-review-20261104/src/entry.zig
  -Mentry_options=<repo>/.scratch/build/architecture-review-20261104/core-options.zig
```

Bybit 使用 bybit-options；Store 使用 store-options；Binance 使用 binance-options 与 `--test-filter "audit "`。
实际上轮以 Python subprocess 参数数组传递，避免 PowerShell 的 -M 参数解析差异。
这些探针以预期安全行为作断言，在未修复基线上失败是本次发现的证据，不是已通过的修复回归。

## Existing passing tests

上轮分别从原源码经 tools/zig-entry.py 执行，均加 `--stack 536870912`，未使用修改后的副本：

| 过滤条件 | 日志 | 结果 |
|---|---|---|
| Binance Testnet sends require | [原日志](../build/architecture-review-20261104/baseline-binance.txt) | 目标测试通过；含 entry 测试共 2/2 |
| Hyperliquid private rebate order | [原日志](../build/architecture-review-20261104/baseline-hyperliquid.txt) | 目标测试通过；含 entry 测试共 2/2 |
| committed recovery prefix retains physical | [原日志](../build/architecture-review-20261104/baseline-store.txt) | 目标测试通过；含 entry 测试共 2/2 |

这些结果说明旧覆盖不能发现本次反例，不是全量 Debug/ReleaseSafe 通过结论。

## Static risks and existing ownership

### R1 Manifest 耐久性

DurableStore 的 appendImpl → persistSegment(false) → writeManifest(false) 将未同步临时 manifest rename 为唯一 manifest。
源码位置 1152、1692、1700、1722–1725。它同时包含之前已提交的恢复引用。
未做目标文件系统断电实验，不能宣称已发生丢失；由 [06](issues/06-manifest-durability.md) 核实并按证据修复。

### R2 Host 有界 I/O

[ManagedHost](../../src/strategy/strategy_host_lifecycle.zig) 632、666、740、765、816 的读取/退出等待没有在该层体现 deadline；
[Windows verification](../../src/runtime/windows_verification_runtime.zig) 326、1048 存在同步调用。
HostSupervisor.poll 有超时状态机，Python package 路径已有外层 watchdog。
未执行真实挂起反例，不能断言全部调用无保护；由 [07](issues/07-host-bounded-io.md) 逐调用方验证。

### 生产接线

[Linux production runtime](../../src/runtime/production_runtime.zig) 1–4、190–264 明确只负责进程生命周期，尚非完整交易业务执行闭环。
归属 [已有生产地图](../production-readiness/map.md)，本图仅记录关联，不建立重复实施票或改其状态。
Windows 与 Linux 的独立资格沿用 ADR 0010。

### 优化候选

TradingShard.apply 的全状态候选复制、Owner 的 demo 目录命名和入口组装分别属于性能测量/职责归属候选。
本次没有负载或尾延迟测量；不把大文件、大栈或目录命名直接定性为缺陷。具体后续条件见 [map](map.md)。

## Documentation-only delivery

用户在本轮明确要求只落实文档，不修改代码做优化。本轮只写此模块的 Markdown，
不修改业务源码或审阅探针，不编译，不重新运行故障实验，不更改 GLOSSARY/ADR 或旧 tracker 状态。
后续实现由单独的任务指令启动；ready-for-agent 只是本地分诊状态。
