# Source layout

2026-10-21 补充：02 新增的 `src/market/depth_snapshot.zig` 注册为独立入口 118，原有入口编号保持不变。04 在迁移后的目录内实现，本次提交同时承接已有目录迁移。Host 传输、身份消费及格式规则见 [04 合同](../.scratch/cross-venue-core-interface/04-host-group-contract.md)，最新离线结果见 [04 验证](../.scratch/cross-venue-core-interface/04-verification.md)。下面的 2026-10-19 结果仅属于原迁移基线。

源文件按职责组织；目录迁移保留现有模块接口、运行参数与持久化格式。

## 目录归属

- `model/`：Venue 中立的规范领域事件。
- `trading/`：TradingShard、权威配置、控制事实和状态演进。
- `execution/`、`risk/`、`portfolio/`、`market/`：订单执行、风控、经济账户与公共行情。
- `adapters/<venue>/`：各交易所的公共行情、私有账户、协议解析与 transport 实现。
- `persistence/`：DurableStore、日志、快照、编码和业务历史证明合同。
- `strategy/`：StrategyHost IPC、生命周期与恢复。
- `runtime/`：进程运行、切换、故障恢复和遥测；`runtime/demo/` 组装 Demo 链路。
- `security/`：凭证存储、密码派生、加密实现、秘密内存及其合成测试数据。
- `testing/`：共享 fixture、契约、独立回归、集成和按用途分类的验收。
- `benchmarks/`：性能测量入口。

目录表达现有职责归属，不表示本次已消除模块间的循环依赖。业务历史批次构造跟随
所属业务模块；持久化 I/O 继续由既有 Owner 和 DurableStore 承担。
文件内单元测试继续与实现放在一起。加密实现的随附许可证与来源说明一并保留。

## 构建与独立入口

`src/main.zig` 和 `src/windows_demo_main.zig` 保持原入口；现有 `zig build` 步骤和
程序参数不变。格式检查需要递归遍历，例如 `zig fmt --check src build.zig`。

Zig 的文件导入受模块根目录约束。子目录文件依赖其他目录时，使用新增的
`src/entry.zig` 分发入口，由 `tools/zig-entry.py` 在编译时选择文件，让模块根目录
保持为 `src/`。例如：

```powershell
python tools/zig-entry.py test src/strategy/strategy_host_gateway.zig -OReleaseSafe --stack 536870912
python tools/zig-entry.py run src/testing/integration/strategy_host_integration.zig -OReleaseSafe --stack 536870912
```

该工具接受 `test`、`run`、`build-exe`、`build-obj` 和 `build-lib`，保留 Zig 编译参数及 `--` 后的
程序参数；选择文件存放在 `.scratch/build/entries/`，使用稳定路径复用 Zig 编译缓存。PowerShell
验收脚本通过 `tools/zig-entry.ps1` 选择同一入口。新增需要独立编译的文件时，在
`src/entry.zig` 中追加一个未使用的数字与字面量导入；现有编号无需调整。

历史报告、归档文档与本地 issue 中记录的旧路径保留原样，查找当前文件可使用下表。

## 验证栈预算

当前完整状态回归在迁移前后的 64 MiB Debug 栈上均发生栈溢出。本次完整 Debug 和
ReleaseSafe 验证使用 `--stack 536870912`，不改变交易状态、持久化格式或产品进程的
栈配置。`python/verify_strategy_host.py` 对独立验收程序显式使用相同的 512 MiB 栈预算。

## 本次迁移验证结果

2026-10-19，基于 `e5731d6b` 的工作区完成以下离线验证：

| 检查 | 结果 |
| --- | --- |
| 逐文件等价核对 | 133 个原有源文件及资源完整保留；实现仅调整 import、embed 和 include 路径 |
| Debug 主回归，512 MiB 栈 | 650/650 通过 |
| ReleaseSafe 主回归，512 MiB 栈 | 650/650 通过 |
| `zig build` | 通过 |
| `zig build windows-demo-bin` | 通过，仅构建 |
| Linux x86_64 GNU 核心交叉编译 | 通过，仅编译 |
| `python python/verify_strategy_host.py` | 14/14 步通过，含恢复、故障隔离及五种容量场景 |
| C transport 合成请求验收 | 通过，无网络 |
| 独立入口与空标准输入编译调用 | 通过 |
| 旧路径与入口检查 | 工具脚本无遗留迁移路径；118 个独立入口有效且唯一 |
| Zig 格式、PowerShell 语法和 diff 空白检查 | 通过 |

131 个原有文件移动到职责目录，两个原有程序入口保持原位；新增统一独立验收入口。
以上结果不扩展既有 Demo、Testnet 或生产资格，历史证据保持原范围。
详细本地日志位于 `.scratch/source-layout/`。

## 完整迁移表

| 原路径 | 当前路径 |
| --- | --- |
| `src/binance_market_feed.zig` | [`src/adapters/binance/binance_market_feed.zig`](../src/adapters/binance/binance_market_feed.zig) |
| `src/binance_order_raw.zig` | [`src/adapters/binance/binance_order_raw.zig`](../src/adapters/binance/binance_order_raw.zig) |
| `src/binance_private_reconciliation.zig` | [`src/adapters/binance/binance_private_reconciliation.zig`](../src/adapters/binance/binance_private_reconciliation.zig) |
| `src/binance_public_market.zig` | [`src/adapters/binance/binance_public_market.zig`](../src/adapters/binance/binance_public_market.zig) |
| `src/binance_venue_adapter.zig` | [`src/adapters/binance/binance_venue_adapter.zig`](../src/adapters/binance/binance_venue_adapter.zig) |
| `src/bybit_market_feed.zig` | [`src/adapters/bybit/bybit_market_feed.zig`](../src/adapters/bybit/bybit_market_feed.zig) |
| `src/bybit_private_reconciliation.zig` | [`src/adapters/bybit/bybit_private_reconciliation.zig`](../src/adapters/bybit/bybit_private_reconciliation.zig) |
| `src/bybit_venue_adapter.zig` | [`src/adapters/bybit/bybit_venue_adapter.zig`](../src/adapters/bybit/bybit_venue_adapter.zig) |
| `src/okx_curl_shim.c` | [`src/adapters/okx/okx_curl_shim.c`](../src/adapters/okx/okx_curl_shim.c) |
| `src/okx_curl_transport.zig` | [`src/adapters/okx/okx_curl_transport.zig`](../src/adapters/okx/okx_curl_transport.zig) |
| `src/okx_market_feed.zig` | [`src/adapters/okx/okx_market_feed.zig`](../src/adapters/okx/okx_market_feed.zig) |
| `src/okx_order_entry.zig` | [`src/adapters/okx/okx_order_entry.zig`](../src/adapters/okx/okx_order_entry.zig) |
| `src/okx_private_reconciliation.zig` | [`src/adapters/okx/okx_private_reconciliation.zig`](../src/adapters/okx/okx_private_reconciliation.zig) |
| `src/okx_private_recovery.zig` | [`src/adapters/okx/okx_private_recovery.zig`](../src/adapters/okx/okx_private_recovery.zig) |
| `src/okx_public_market.zig` | [`src/adapters/okx/okx_public_market.zig`](../src/adapters/okx/okx_public_market.zig) |
| `src/okx_rest_auth.zig` | [`src/adapters/okx/okx_rest_auth.zig`](../src/adapters/okx/okx_rest_auth.zig) |
| `src/okx_venue_adapter.zig` | [`src/adapters/okx/okx_venue_adapter.zig`](../src/adapters/okx/okx_venue_adapter.zig) |
| `src/simulated_market_feed.zig` | [`src/adapters/simulated/simulated_market_feed.zig`](../src/adapters/simulated/simulated_market_feed.zig) |
| `src/simulated_venue.zig` | [`src/adapters/simulated/simulated_venue.zig`](../src/adapters/simulated/simulated_venue.zig) |
| `src/trading_shard_benchmark.zig` | [`src/benchmarks/trading_shard_benchmark.zig`](../src/benchmarks/trading_shard_benchmark.zig) |
| `src/execution_gateway.zig` | [`src/execution/execution_gateway.zig`](../src/execution/execution_gateway.zig) |
| `src/oms.zig` | [`src/execution/oms.zig`](../src/execution/oms.zig) |
| `src/order_history_batch.zig` | [`src/execution/order_history_batch.zig`](../src/execution/order_history_batch.zig) |
| `src/venue_adapter.zig` | [`src/execution/venue_adapter.zig`](../src/execution/venue_adapter.zig) |
| `src/main.zig` | [`src/main.zig`](../src/main.zig) |
| `src/market_feed_adapter.zig` | [`src/market/market_feed_adapter.zig`](../src/market/market_feed_adapter.zig) |
| `src/market_projection.zig` | [`src/market/market_projection.zig`](../src/market/market_projection.zig) |
| `src/canonical_event.zig` | [`src/model/canonical_event.zig`](../src/model/canonical_event.zig) |
| `src/business_history.zig` | [`src/persistence/business_history.zig`](../src/persistence/business_history.zig) |
| `src/canonical_event_codec.zig` | [`src/persistence/canonical_event_codec.zig`](../src/persistence/canonical_event_codec.zig) |
| `src/durable_store.zig` | [`src/persistence/durable_store.zig`](../src/persistence/durable_store.zig) |
| `src/journal.zig` | [`src/persistence/journal.zig`](../src/persistence/journal.zig) |
| `src/raw_ingress.zig` | [`src/persistence/raw_ingress.zig`](../src/persistence/raw_ingress.zig) |
| `src/snapshot_codec.zig` | [`src/persistence/snapshot_codec.zig`](../src/persistence/snapshot_codec.zig) |
| `src/account_coordinator.zig` | [`src/portfolio/account_coordinator.zig`](../src/portfolio/account_coordinator.zig) |
| `src/account_projection.zig` | [`src/portfolio/account_projection.zig`](../src/portfolio/account_projection.zig) |
| `src/economics.zig` | [`src/portfolio/economics.zig`](../src/portfolio/economics.zig) |
| `src/fill_history_batch.zig` | [`src/portfolio/fill_history_batch.zig`](../src/portfolio/fill_history_batch.zig) |
| `src/forced_archive_proof.zig` | [`src/portfolio/forced_archive_proof.zig`](../src/portfolio/forced_archive_proof.zig) |
| `src/forced_history_batch.zig` | [`src/portfolio/forced_history_batch.zig`](../src/portfolio/forced_history_batch.zig) |
| `src/funding_history_batch.zig` | [`src/portfolio/funding_history_batch.zig`](../src/portfolio/funding_history_batch.zig) |
| `src/reconciliation_history_batch.zig` | [`src/portfolio/reconciliation_history_batch.zig`](../src/portfolio/reconciliation_history_batch.zig) |
| `src/risk.zig` | [`src/risk/risk.zig`](../src/risk/risk.zig) |
| `src/cutover_history.zig` | [`src/runtime/cutover_history.zig`](../src/runtime/cutover_history.zig) |
| `src/demo_authority.zig` | [`src/runtime/demo/demo_authority.zig`](../src/runtime/demo/demo_authority.zig) |
| `src/okx_demo_account_guard.zig` | [`src/runtime/demo/okx_demo_account_guard.zig`](../src/runtime/demo/okx_demo_account_guard.zig) |
| `src/okx_demo_credential_input.zig` | [`src/runtime/demo/okx_demo_credential_input.zig`](../src/runtime/demo/okx_demo_credential_input.zig) |
| `src/okx_live_chain.zig` | [`src/runtime/demo/okx_live_chain.zig`](../src/runtime/demo/okx_live_chain.zig) |
| `src/failover.zig` | [`src/runtime/failover.zig`](../src/runtime/failover.zig) |
| `src/production_contract.zig` | [`src/runtime/production_contract.zig`](../src/runtime/production_contract.zig) |
| `src/production_runtime.zig` | [`src/runtime/production_runtime.zig`](../src/runtime/production_runtime.zig) |
| `src/recovery_cutover.zig` | [`src/runtime/recovery_cutover.zig`](../src/runtime/recovery_cutover.zig) |
| `src/telemetry_qualification.zig` | [`src/runtime/telemetry_qualification.zig`](../src/runtime/telemetry_qualification.zig) |
| `src/windows_verification_runtime.zig` | [`src/runtime/windows_verification_runtime.zig`](../src/runtime/windows_verification_runtime.zig) |
| `src/credential_aead.zig` | [`src/security/credential_aead.zig`](../src/security/credential_aead.zig) |
| `src/credential_aead_crypto/LICENSE` | [`src/security/credential_aead_crypto/LICENSE`](../src/security/credential_aead_crypto/LICENSE) |
| `src/credential_aead_crypto/README.md` | [`src/security/credential_aead_crypto/README.md`](../src/security/credential_aead_crypto/README.md) |
| `src/credential_aead_crypto/chacha20_core.zig` | [`src/security/credential_aead_crypto/chacha20_core.zig`](../src/security/credential_aead_crypto/chacha20_core.zig) |
| `src/credential_aead_crypto/poly1305.zig` | [`src/security/credential_aead_crypto/poly1305.zig`](../src/security/credential_aead_crypto/poly1305.zig) |
| `src/credential_crypto/LICENSE` | [`src/security/credential_crypto/LICENSE`](../src/security/credential_crypto/LICENSE) |
| `src/credential_crypto/README.md` | [`src/security/credential_crypto/README.md`](../src/security/credential_crypto/README.md) |
| `src/credential_crypto/argon2.zig` | [`src/security/credential_crypto/argon2.zig`](../src/security/credential_crypto/argon2.zig) |
| `src/credential_crypto/blake2b.zig` | [`src/security/credential_crypto/blake2b.zig`](../src/security/credential_crypto/blake2b.zig) |
| `src/credential_crypto/sha256.zig` | [`src/security/credential_crypto/sha256.zig`](../src/security/credential_crypto/sha256.zig) |
| `src/credential_kdf.zig` | [`src/security/credential_kdf.zig`](../src/security/credential_kdf.zig) |
| `src/credential_store.zig` | [`src/security/credential_store.zig`](../src/security/credential_store.zig) |
| `src/protected_memory.zig` | [`src/security/protected_memory.zig`](../src/security/protected_memory.zig) |
| `src/testdata/credential-store-crd4-v1-synthetic.credential` | [`src/security/testdata/credential-store-crd4-v1-synthetic.credential`](../src/security/testdata/credential-store-crd4-v1-synthetic.credential) |
| `src/strategy_host_failures.zig` | [`src/strategy/strategy_host_failures.zig`](../src/strategy/strategy_host_failures.zig) |
| `src/strategy_host_gateway.zig` | [`src/strategy/strategy_host_gateway.zig`](../src/strategy/strategy_host_gateway.zig) |
| `src/strategy_host_ipc.zig` | [`src/strategy/strategy_host_ipc.zig`](../src/strategy/strategy_host_ipc.zig) |
| `src/strategy_host_lifecycle.zig` | [`src/strategy/strategy_host_lifecycle.zig`](../src/strategy/strategy_host_lifecycle.zig) |
| `src/strategy_host_recovery.zig` | [`src/strategy/strategy_host_recovery.zig`](../src/strategy/strategy_host_recovery.zig) |
| `src/continuous_account_acceptance.zig` | [`src/testing/acceptance/accounting/continuous_account_acceptance.zig`](../src/testing/acceptance/accounting/continuous_account_acceptance.zig) |
| `src/native_account_continuity_acceptance.zig` | [`src/testing/acceptance/accounting/native_account_continuity_acceptance.zig`](../src/testing/acceptance/accounting/native_account_continuity_acceptance.zig) |
| `src/native_economic_reconciliation_acceptance.zig` | [`src/testing/acceptance/accounting/native_economic_reconciliation_acceptance.zig`](../src/testing/acceptance/accounting/native_economic_reconciliation_acceptance.zig) |
| `src/native_multi_venue_accounting_acceptance.zig` | [`src/testing/acceptance/accounting/native_multi_venue_accounting_acceptance.zig`](../src/testing/acceptance/accounting/native_multi_venue_accounting_acceptance.zig) |
| `src/simulated_native_accounting_acceptance.zig` | [`src/testing/acceptance/accounting/simulated_native_accounting_acceptance.zig`](../src/testing/acceptance/accounting/simulated_native_accounting_acceptance.zig) |
| `src/continuous_backpressure_acceptance.zig` | [`src/testing/acceptance/capacity/continuous_backpressure_acceptance.zig`](../src/testing/acceptance/capacity/continuous_backpressure_acceptance.zig) |
| `src/continuous_capacity_acceptance.zig` | [`src/testing/acceptance/capacity/continuous_capacity_acceptance.zig`](../src/testing/acceptance/capacity/continuous_capacity_acceptance.zig) |
| `src/core_observation_capacity_acceptance.zig` | [`src/testing/acceptance/capacity/core_observation_capacity_acceptance.zig`](../src/testing/acceptance/capacity/core_observation_capacity_acceptance.zig) |
| `src/order_capacity_acceptance.zig` | [`src/testing/acceptance/capacity/order_capacity_acceptance.zig`](../src/testing/acceptance/capacity/order_capacity_acceptance.zig) |
| `src/order_public_capacity_acceptance.zig` | [`src/testing/acceptance/capacity/order_public_capacity_acceptance.zig`](../src/testing/acceptance/capacity/order_public_capacity_acceptance.zig) |
| `src/strategy_host_capacity.zig` | [`src/testing/acceptance/capacity/strategy_host_capacity.zig`](../src/testing/acceptance/capacity/strategy_host_capacity.zig) |
| `src/windows_capacity_acceptance.zig` | [`src/testing/acceptance/capacity/windows_capacity_acceptance.zig`](../src/testing/acceptance/capacity/windows_capacity_acceptance.zig) |
| `src/windows_capacity_fault_acceptance.zig` | [`src/testing/acceptance/capacity/windows_capacity_fault_acceptance.zig`](../src/testing/acceptance/capacity/windows_capacity_fault_acceptance.zig) |
| `src/cold_core_protocol_acceptance.zig` | [`src/testing/acceptance/core/cold_core_protocol_acceptance.zig`](../src/testing/acceptance/core/cold_core_protocol_acceptance.zig) |
| `src/control_resident_order_acceptance.zig` | [`src/testing/acceptance/core/control_resident_order_acceptance.zig`](../src/testing/acceptance/core/control_resident_order_acceptance.zig) |
| `src/coordination_gateway_acceptance.zig` | [`src/testing/acceptance/core/coordination_gateway_acceptance.zig`](../src/testing/acceptance/core/coordination_gateway_acceptance.zig) |
| `src/coordinator_safety_acceptance.zig` | [`src/testing/acceptance/core/coordinator_safety_acceptance.zig`](../src/testing/acceptance/core/coordinator_safety_acceptance.zig) |
| `src/four_shard_acceptance.zig` | [`src/testing/acceptance/core/four_shard_acceptance.zig`](../src/testing/acceptance/core/four_shard_acceptance.zig) |
| `src/control_archive_acceptance.zig` | [`src/testing/acceptance/history/control_archive_acceptance.zig`](../src/testing/acceptance/history/control_archive_acceptance.zig) |
| `src/control_gateway_retention_acceptance.zig` | [`src/testing/acceptance/history/control_gateway_retention_acceptance.zig`](../src/testing/acceptance/history/control_gateway_retention_acceptance.zig) |
| `src/coordinator_history_acceptance.zig` | [`src/testing/acceptance/history/coordinator_history_acceptance.zig`](../src/testing/acceptance/history/coordinator_history_acceptance.zig) |
| `src/fill_archive_acceptance.zig` | [`src/testing/acceptance/history/fill_archive_acceptance.zig`](../src/testing/acceptance/history/fill_archive_acceptance.zig) |
| `src/forced_archive_acceptance.zig` | [`src/testing/acceptance/history/forced_archive_acceptance.zig`](../src/testing/acceptance/history/forced_archive_acceptance.zig) |
| `src/funding_archive_acceptance.zig` | [`src/testing/acceptance/history/funding_archive_acceptance.zig`](../src/testing/acceptance/history/funding_archive_acceptance.zig) |
| `src/order_dispatch_archive_acceptance.zig` | [`src/testing/acceptance/history/order_dispatch_archive_acceptance.zig`](../src/testing/acceptance/history/order_dispatch_archive_acceptance.zig) |
| `src/order_gateway_archive_acceptance.zig` | [`src/testing/acceptance/history/order_gateway_archive_acceptance.zig`](../src/testing/acceptance/history/order_gateway_archive_acceptance.zig) |
| `src/order_history_safety_acceptance.zig` | [`src/testing/acceptance/history/order_history_safety_acceptance.zig`](../src/testing/acceptance/history/order_history_safety_acceptance.zig) |
| `src/reconciliation_archive_acceptance.zig` | [`src/testing/acceptance/history/reconciliation_archive_acceptance.zig`](../src/testing/acceptance/history/reconciliation_archive_acceptance.zig) |
| `src/reconciliation_archive_safety_acceptance.zig` | [`src/testing/acceptance/history/reconciliation_archive_safety_acceptance.zig`](../src/testing/acceptance/history/reconciliation_archive_safety_acceptance.zig) |
| `src/asset_precision_file_recovery_acceptance.zig` | [`src/testing/acceptance/platform/asset_precision_file_recovery_acceptance.zig`](../src/testing/acceptance/platform/asset_precision_file_recovery_acceptance.zig) |
| `src/windows_observation_file_acceptance.zig` | [`src/testing/acceptance/platform/windows_observation_file_acceptance.zig`](../src/testing/acceptance/platform/windows_observation_file_acceptance.zig) |
| `src/binance_testnet_acceptance.zig` | [`src/testing/acceptance/venues/binance_testnet_acceptance.zig`](../src/testing/acceptance/venues/binance_testnet_acceptance.zig) |
| `src/bybit_testnet_acceptance.zig` | [`src/testing/acceptance/venues/bybit_testnet_acceptance.zig`](../src/testing/acceptance/venues/bybit_testnet_acceptance.zig) |
| `src/multi_venue_testnet_acceptance.zig` | [`src/testing/acceptance/venues/multi_venue_testnet_acceptance.zig`](../src/testing/acceptance/venues/multi_venue_testnet_acceptance.zig) |
| `src/okx_curl_private_smoke.zig` | [`src/testing/acceptance/venues/okx_curl_private_smoke.zig`](../src/testing/acceptance/venues/okx_curl_private_smoke.zig) |
| `src/okx_curl_public_smoke.zig` | [`src/testing/acceptance/venues/okx_curl_public_smoke.zig`](../src/testing/acceptance/venues/okx_curl_public_smoke.zig) |
| `src/okx_demo_live_acceptance.zig` | [`src/testing/acceptance/venues/okx_demo_live_acceptance.zig`](../src/testing/acceptance/venues/okx_demo_live_acceptance.zig) |
| `src/venue_fill_recovery_acceptance.zig` | [`src/testing/acceptance/venues/venue_fill_recovery_acceptance.zig`](../src/testing/acceptance/venues/venue_fill_recovery_acceptance.zig) |
| `src/historical_fee_audit.zig` | [`src/testing/audit/historical_fee_audit.zig`](../src/testing/audit/historical_fee_audit.zig) |
| `src/historical_fee_audit_samples.json` | [`src/testing/audit/historical_fee_audit_samples.json`](../src/testing/audit/historical_fee_audit_samples.json) |
| `src/venue_adapter_contract.zig` | [`src/testing/contracts/venue_adapter_contract.zig`](../src/testing/contracts/venue_adapter_contract.zig) |
| `src/strategy_host_failure_integration.zig` | [`src/testing/integration/strategy_host_failure_integration.zig`](../src/testing/integration/strategy_host_failure_integration.zig) |
| `src/strategy_host_integration.zig` | [`src/testing/integration/strategy_host_integration.zig`](../src/testing/integration/strategy_host_integration.zig) |
| `src/strategy_host_recovery_integration.zig` | [`src/testing/integration/strategy_host_recovery_integration.zig`](../src/testing/integration/strategy_host_recovery_integration.zig) |
| `src/credential_store_visibility_test.zig` | [`src/testing/regression/credential_store_visibility_test.zig`](../src/testing/regression/credential_store_visibility_test.zig) |
| `src/okx_auth_transport_synthetic_test.zig` | [`src/testing/regression/okx_auth_transport_synthetic_test.zig`](../src/testing/regression/okx_auth_transport_synthetic_test.zig) |
| `src/okx_curl_shim_request_test.c` | [`src/testing/regression/okx_curl_shim_request_test.c`](../src/testing/regression/okx_curl_shim_request_test.c) |
| `src/trading_shard_tests.zig` | [`src/testing/regression/trading_shard_tests.zig`](../src/testing/regression/trading_shard_tests.zig) |
| `src/file_acceptance_runtime.zig` | [`src/testing/support/file_acceptance_runtime.zig`](../src/testing/support/file_acceptance_runtime.zig) |
| `src/simulated_lifecycle_projection.zig` | [`src/testing/support/simulated_lifecycle_projection.zig`](../src/testing/support/simulated_lifecycle_projection.zig) |
| `src/trading_shard_fixture.zig` | [`src/testing/support/trading_shard_fixture.zig`](../src/testing/support/trading_shard_fixture.zig) |
| `src/windows_capacity_shared.zig` | [`src/testing/support/windows_capacity_shared.zig`](../src/testing/support/windows_capacity_shared.zig) |
| `src/asset_registry.zig` | [`src/trading/asset_registry.zig`](../src/trading/asset_registry.zig) |
| `src/cold_business_candidate.zig` | [`src/trading/cold_business_candidate.zig`](../src/trading/cold_business_candidate.zig) |
| `src/control_history_batch.zig` | [`src/trading/control_history_batch.zig`](../src/trading/control_history_batch.zig) |
| `src/instrument_registry.zig` | [`src/trading/instrument_registry.zig`](../src/trading/instrument_registry.zig) |
| `src/operational.zig` | [`src/trading/operational.zig`](../src/trading/operational.zig) |
| `src/trading_shard.zig` | [`src/trading/trading_shard.zig`](../src/trading/trading_shard.zig) |
| `src/trading_shard_event.zig` | [`src/trading/trading_shard_event.zig`](../src/trading/trading_shard_event.zig) |
| `src/windows_demo_main.zig` | [`src/windows_demo_main.zig`](../src/windows_demo_main.zig) |
