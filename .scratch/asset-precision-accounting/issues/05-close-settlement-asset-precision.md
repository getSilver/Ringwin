# 05：贯通高精度结算资产费用与原币账务

Type: task
Status: done
Assignee: codex/asset-precision-accounting
Blocked by: [04：贯通 AssetDefinition 激活与精度范围准入](04-activate-authoritative-asset-precision.md)
Parent: [落实权威资产精度与精确经济账务](../map.md)
Spec: [父 Spec](01-exact-asset-accounting-spec.md)
Label: completed
Phase: S3

## Question

如何通过既有公开 interface 完成“贯通高精度结算资产费用与原币账务”，并证明本票对应的经济、安全及恢复行为满足父 Spec？

## What to build

配置精度下的结算资产费用、返佣、现金、posting 与风险计算使用一致单位，单笔和累计金额保持精确。

## Acceptance criteria

- [x] 十二位测试配置中两组指定 USDT 费用分别精确记为 4198632165 与 4237238520 atoms；十笔 0.0000001 费用精确累计 0.000001 USDT。
- [x] fee/rebate 独立原币 posting；不把正返佣舍零、零当缺失，不改写成交数量或 OMS 报告累计值。
- [x] 消除本切片金额状态、posting、累计及资金限制的 i64 窄化；按已准入范围选既有宽整数，不无差别扩大身份与数量字段。
- [x] 价格 ticks、数量 lots、tick 价值、数量尺度与合约乘数计算名义/结算金额时单位明确；扩大 USDT 精度不改变真实经济值。
- [x] 风险预估和预留的显式保守舍入保留，但实际费用/余额禁止取整；确需 Venue 产品结算舍入时绑定规则版本与独立差分证据。
- [x] 逐 Asset 内部双层闭合、重复 no-op、冲突和累计溢出均通过 Owner→TradingShard→账本→持久与重放验证；失败无局部经济提交。
- [x] 如共享金额重定型无法逐切片落地，使用隔离集成分支承载关联修改并明确绿色验收点；不得在旧 schema 中写入新状态、不得创建并行权威账本或猜测迁移。

## Testing decisions

- 验收沿用户确认的公开接缝：VenueAdapter 的 ingestPrivateWs/REST → tryDrain → 既有 Owner/applyAdapterBatch → TradingShard.apply → DurableStore → snapshot/replay。
- 本票涉及 Decimal 公共数值合同时，只补 Decimal.parse/exactAtoms 边界检查；不直接测试私有 helper，不新增测试专用 interface。
- 测试独立固定整数与明确尺度，不用被测函数计算 expected；按范围验证 Debug、ReleaseSafe 及必要的 codec/状态检查，复用既有 fixture、故障注入和验收入口。
- 每个有持久语义变化的可运行切片同步闭合 schema、codec、snapshot 与 digest；不延期到最终验收票补做，不把新状态写入旧 schema。

## Spec coverage

- User Stories：01、02、03、04、07、08、09、23、24。
- Implementation Decisions：D2、D3、D6、D7。
- 验收矩阵：M01、M02、M04、M09、M12、M13。
- D/M 编号含义及完整覆盖关系见[模块地图](../map.md#spec-coverage)。

## Boundaries

- 只完成本票交付及其直接必需变更，复用同一核心、账本和外围 seam，保留无关工作树改动。
- 不放宽幂等、overfill、来源粒度、账户隔离、checked arithmetic、对账或 SafetyGate；不增加浮点、BigInt、通用余数账本或自动重发。
- 本地实现/离线检查不授权部署、Demo/Testnet/生产写入、清理、历史账更正或新版本在线资格；父 Spec 的其他排除项继续适用。
- 不修改或关闭父 Spec，不同步 GitHub Issues。完成时在本票追加实际证据并更新地图，尚未执行的验收项保持未勾选。

## Evidence

2026-10-05：认领当前 Frontier 05；实施沿既有 Adapter→Owner→Core→DurableStore 公开接缝推进，尚未关闭任何验收项。金额字段使用显式结算 atoms，数量 lots、价格 ticks 与身份宽度保持独立；首次成功/故障切片由公开 Owner 验收驱动。


2026-10-05：本票离线切片完成，独立工作区 `D:\github\Ringwin-asset-precision-accounting`，分支 `codex/asset-precision-accounting`；基线 `51a2870d`，Zig `0.17.0-dev.315+5b647b792`。原工作树与父 Spec 原文、状态保持不变。

- 金额状态、风险预留/限制、原币 cash/fee/rebate、posting、成本/PnL 和账户协调资金字段改为 checked i128 settlement atoms。身份、lots、ticks 及 Host 的既有六位价格 ABI 保持各自单位；报价计算显式使用 `quantity lots × price ticks × price_tick_atoms / quantity_denominator`。实际结算有余数时持久失败关闭，风险预估保留原有保守舍入。
- Policy schema 2 必须给出权威资产定义及 tick atoms；既有 Owner 在私有 bootstrap 前提交 instrument/margin/native 配置，Adapter 从提交状态取得单位。初始化复用相同配置，不制造第二套权威状态。非兼容 base/第三资产消费者仍待 06/07，不因结算金额迁移获得资格。
- 原始 OKX WS 经 `ingestPrivateWs → tryDrain → Owner.applyAdapterBatch → TradingShard → ledger → log/snapshot/recover`：十二位费用固定 expected 为 `4198632165`、`4237238520`；十笔微额费用累计 `1000000` atoms；正返佣为 `100000` atoms，显式零保持零。逐层独立 fee/rebate posting 使用 settlement atoms，重复为 no-op。
- 十八位配置用实际 `100 USDT = 100000000000000000000 atoms` 验证超过 i64 的资金和余额，未窄化。累计费用第二笔越界时，OMS 保留两笔报告累计 `20000 lots`，唯一经济成交只有 `10000 lots`，账本停在第一笔；原始费用身份冲突、实际 subatom notional 和畸形终态报告均无局部经济提交，并可日志及快照恢复安全栅栏。
- 真实多笔验收暴露 OMS 把 canonical digest 身份当递增报告号的问题；共享 OMS 按 revision/cumulative/status 判断进度，保留身份去重与冲突检查，旧非 canonical 报告保留原序号合同。合法迟到 Accepted 和减量 amend 历史报告不回退状态；非法终态先验证再分类。Core 持久关闭其风险，重放只接纳已生成且逐项核验的失败事实组。
- 持久版本同步更新：canonical/encoding 6，journal 26，state 30，schema registry 24；AccountCoordinator snapshot 6、input 3。旧 schema 不解释成新 atoms，不猜测历史迁移。五条既有 fixture 和四分片闭合/恢复轨迹经实际执行后更新当前黄金 digest。

验证：

```powershell
zig test src/main.zig -ODebug --stack 67108864 --test-filter 'fixed trajectories' --test-filter 'four-shard acceptance entry' --test-filter 'OKX native settlement' --test-filter 'Windows retained committed' --test-filter 'Windows file reopen recovers' --test-filter 'OKX raw private fills' --test-filter 'SPOT and linear instruments' --test-filter 'OKX ready economic faults'
# 同一命令 -OReleaseSafe：两种构建均 15/15。
```

- economics Debug/ReleaseSafe 各 13/13；risk 各 8/8；OMS 完整模块各 27/27；AccountCoordinator Debug 定向 22/22、ReleaseSafe 完整模块 91/91（22 项本模块及 69 项导入检查）；DemoPolicy 两种构建定向各 3/3。
- `zig build-exe src/main.zig -ODebug --stack 67108864 '-femit-bin=.scratch/build/settlement-05-debug.exe'` 及 ReleaseSafe 对应构建通过。两个实际二进制分别执行 `--offline-fixture`，全部五轨迹闭合/重放通过且同轨迹跨构建 digest 一致；happy/dedup 为 `19a6da355b7275a9a46b0a84b6a2bc443a5c227f395a6ae505d844e3bc3387f9`。
- 两种实际二进制 `--windows-chain-test` exit 0，`private_raw_barrier=27`、`spot_atoms=20000`、`role_ownership=passed`、`durable_recovery=passed`；日志在忽略的 `.scratch/build/settlement-05-{debug,rs}-chain.log`。预期负例验证通过，聚合线上资格仍为 blocked/false。
- Linux authoritative 编译通过：`zig build-obj src/okx_demo_live_acceptance.zig src/okx_curl_shim.c -target x86_64-linux-gnu -OReleaseSafe -lc '-ID:\github\Ringwin\.scratch\build\bootstrap\curl-source\curl-8.21.0\include' -fno-emit-bin`。只读复用 curl 头文件，无在线执行。
- `zig fmt --check` 所有变更 Zig 文件与 `git diff --check` 通过；两名 Sol 6.1 medium 子代理分别完成 Standards/Spec 并复核，最终均无剩余发现。完整 main suite 仍按实施流程在 14 统一运行。

本票完成不授权部署、任何真实/Demo/Testnet 写入、清理或历史更正；新源码在线及生产资格仍为 false。Frontier 推进到 06，父 Spec 保持原状态。
