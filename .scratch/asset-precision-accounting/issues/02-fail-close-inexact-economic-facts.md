# 02：停止真实金额取整并持久关闭新增风险

Type: task
Status: done
Assignee: codex/asset-precision-accounting
Blocked by: 无（可立即开始）
Parent: [落实权威资产精度与精确经济账务](../map.md)
Spec: [父 Spec](01-exact-asset-accounting-spec.md)
Label: ready-for-agent
Phase: S1

## Question

如何通过既有公开 interface 完成“停止真实金额取整并持久关闭新增风险”，并证明本票对应的经济、安全及恢复行为满足父 Spec？

## What to build

OKX 已确认的费用、返佣和账户金额无法精确表达时，不再制造取整金额；从 ready 接入到核心安全栅栏、Gateway 和重启形成明确故障结果。

## Acceptance criteria

- [x] 所有真实金额调用路径取消 floor/ceil 兜底；六位 USDT 下给定微费用、微返佣和九位 BTC 样本无虚假 posting，精确旧样本保持正确。
- [x] 区分零、缺失、未知 Asset、格式、非零余数和溢出；保留 RawEvidenceRef。累计订单费用不能伪装成单笔费用；缺失币种不靠报价币猜补。
- [x] 无 pending reconciliation 时也可经 tryDrain、Owner 与 TradingShard 获得账户范围规范故障，不制造 reconciliation request、不只打印错误或返回健康空批次。
- [x] Decoder、Adapter 和核心拒绝均撤销新增风险；不重发、不过早记为已应用 Fill，不释放未决 Unknown/占用；允许安全合同证明的撤单与对账，Reduce-only 不绕过不可信数量。
- [x] 输出不足保留未发布来源，持久化失败本地立即关闭发送；重启恢复未完成来源并保持锁存，重新连接不能自动恢复人工授权。
- [x] 故障及精确成功样本沿公共 seam、DurableStore、codec、snapshot/replay 验证；新持久语义立即提升对应 schema，replay 无外发。
- [x] 本票只证明安全止损，不授权部署部分修复或宣称正式多币种交易已可用。

## Testing decisions

- 验收沿用户确认的公开接缝：VenueAdapter 的 ingestPrivateWs/REST → tryDrain → 既有 Owner/applyAdapterBatch → TradingShard.apply → DurableStore → snapshot/replay。
- 本票涉及 Decimal 公共数值合同时，只补 Decimal.parse/exactAtoms 边界检查；不直接测试私有 helper，不新增测试专用 interface。
- 测试独立固定整数与明确尺度，不用被测函数计算 expected；按范围验证 Debug、ReleaseSafe 及必要的 codec/状态检查，复用既有 fixture、故障注入和验收入口。
- 每个有持久语义变化的可运行切片同步闭合 schema、codec、snapshot 与 digest；不延期到最终验收票补做，不把新状态写入旧 schema。

## Spec coverage

- User Stories：01、03、12、15、16、17、18、19、20、21、28。
- Implementation Decisions：D1、D2、D5、D7。
- 验收矩阵：M01、M02、M03、M04、M10、M11。
- D/M 编号含义及完整覆盖关系见[模块地图](../map.md#spec-coverage)。

## Boundaries

- 只完成本票交付及其直接必需变更，复用同一核心、账本和外围 seam，保留无关工作树改动。
- 不放宽幂等、overfill、来源粒度、账户隔离、checked arithmetic、对账或 SafetyGate；不增加浮点、BigInt、通用余数账本或自动重发。
- 本地实现/离线检查不授权部署、Demo/Testnet/生产写入、清理、历史账更正或新版本在线资格；父 Spec 的其他排除项继续适用。
- 不修改或关闭父 Spec，不同步 GitHub Issues。完成时在本票追加实际证据并更新地图，尚未执行的验收项保持未勾选。

## Evidence

- 运输响应 RawIngress 保存失败的回归实际复现了第二次运输调用仍执行。Chain 现在在运输已调用后的任何证据/分类错误上锁存 Unknown，不重发；直接 `zig test src/okx_live_chain.zig -ODebug` 40/40、ReleaseSafe 的 `response persistence failure` 1/1 通过。该模块已纳入主测试入口；最初使用 main 的同名过滤只有根测试 1/1，未执行回归，不作为通过证据。

2026-10-04 启动接入补充（仍实施中）：Owner 的所有持久化关闭路径现在同时关闭 shard 准入。回归先复现决策日志 EIO 后，独立健康 dispatch Store 的直接 Gateway 仍接受新命令；修复后不再发送且经济 digest 保持不变，Demo owner/policy 定向 Debug、ReleaseSafe 各 4/4。Linux 实际入口已使用 DurableSink(93) 保存私有原文，并在在线接入前调用完整重放；实际 Linux 入口和 C shim 的 ReleaseSafe `zig build-obj ... -target x86_64-linux-gnu -lc -fno-emit-bin` 通过，`OKX ready` Debug 3/3。逐事实索引、部分同帧提交和 Windows 跨进程启动接入仍在核验，本票不关闭。

2026-10-04：在独立工作区 `D:\github\Ringwin-asset-precision-accounting`、分支 `codex/asset-precision-accounting` 实施中；尚不关闭本票或解锁 03。

- 原有六位 USDT、八位 BTC 的真实金额转换已移除取整兜底；新增账户范围 `economic_fault`，保留 RawEvidenceRef，并经既有 Owner、TradingShard、日志、快照及 replay 锁存新增风险关闭。canonical/schema 与 encoding 升至 3，journal/state/registry 升至 23/26/20。
- ready 模式无对账请求的账户金额故障、微费用/返佣、未知资产、缺失/格式/溢出，以及核心经济拒绝已有公开路径回归。核心拒绝回滚候选经济状态后持久化安全状态，不写应用 Fill 标记。
- Gateway 与 Adapter 的共享发送路径允许有完整安全依据的撤单，继续拒绝新增风险；实际 mock transport 的 attempt 计数证明撤单进入发送路径。输出不足保留未消费帧，重试后发布对应故障证据。
- `zig test src/main.zig -ODebug --stack 67108864 --test-filter 'core rejected'`：2/2 通过。针对 ready 与持久化故障的原有 Debug/ReleaseSafe 检查通过；2026-10-04 正在扩展 REST 字段拒绝、Unknown 占用和真实文件重开检查，扩展后的结果另行记录。
- OKX [官方字段合同](https://www.okx.com/docs-v5/en/)明确 WS `fillFee` 和 fills-history `fee` 是本次成交的有符号费用/返佣；订单累计 `fee/rebate` 不能附加为第二笔单次经济作用。WS 已保留累计字段为原始证据而不记入 Fill，REST 不再以其他字段猜补缺失费用或币种。
- 新增同帧发布预检：在临时 Adapter 候选状态验证完整 ready 来源的规范转换，遇到经济拒绝只发布故障，不让同帧 execution_report 先释放 Unknown 占用。回归先发现 reservation 从 2 降为 1，修复后保持原始占用；微费用及 Decoder 拒绝经 WS/REST、Owner/replay/snapshot 验证，重新连接和 reduce-only 不能绕过发送关闭。
- 扩展后的 `zig test src/main.zig -OReleaseSafe --stack 67108864 --test-filter 'OKX ready economic faults'`：2/2 通过。`zig test src/main.zig -ODebug --stack 67108864 --test-filter 'OKX raw private fills'`：2/2 通过，非零累计返佣字段未重复记账，单次正 `fillFee` 仍按返佣入账。格式与 diff 检查通过。
- 真实 WindowsFileAdapter 已补 append/commit 故障与两次关闭重开检查（Debug 2/2）：append 故障时恢复已提交 Owner 前缀，公开 RawIngress 重放恢复经济故障，完整 Unknown 占用不释放；再次重开保持故障及 digest。commit 故障保留未完成尾部，Owner 在两次重开均拒绝恢复，RawIngress 仍可只读重放产生故障，两条分支均无 transport 调用。
- 文件重开检查最终 Debug/ReleaseSafe 均 2/2 通过：`zig test src/main.zig -ODebug --stack 67108864 --test-filter 'Windows file reopen recovers or closes an uncommitted OKX economic fault'`，将 `-ODebug` 换为 `-OReleaseSafe` 结果相同。仅用公开 Store vtable 和既有 FileAdapter 故障注入，不增加产品测试接口。
- 后续核心账户拒绝检查复现了 SourceSequenceGap 未设置 OMS recovery_only 的缺口；已复用经济故障锁存，保留原始证据并绑定安全撤单权限，日志/快照/replay 结果一致。另一条公开 TradingShard 检查发现外部账户观察会使本账户失效，现先核对 envelope、payload 和已绑定账户，不接受跨账户 bootstrap/observation。`zig test src/main.zig -ODebug --stack 67108864 --test-filter 'core rejected'`：2/2；`--test-filter 'account'`：40/40。
- 后续核心拒绝 ReleaseSafe 检查 2/2，account Debug 检查 40/40，snapshot Debug 检查 19/19，production contract Debug 检查 2/2，覆盖账户拒绝、持久状态及 schema 形状变更。
- 已实现恢复准入：每次 Owner.recover 都重新关闭新增风险；Owner.send、直接 Gateway 与核心新风险输入均检查恢复栅栏，核心在改变状态或写日志前拒绝。恢复快照携带该关闭状态，支持现有安全撤单证明。临时移除 Gateway guard 的回归实际产生 `.accepted`，恢复 guard 后拒绝，证明测试对发送缺口敏感。
- recoverWithIngress 显式绑定 RawIngress 流，Owner.replayCommittedIngress 负责完整、稳定提交屏障的重放；未绑定、错误流或失败重放不能解锁。真实 OKX parser/drain/apply 重放后仍保留经济与 OMS 锁存，不以空 consumer 的计数冒充业务恢复完成。新 admission 字段随快照编码，state/registry 升至 27/21；它是进程准入状态，不参与规范经济状态 digest，也不产生不可重放的临时拒绝日志。
- 恢复准入最终组合检查：Demo policy 与真实文件重开在 Debug/ReleaseSafe 均 3/3；只读 Demo owner 检查 3/3。恢复中的快照安全撤单经 `OKX ready inexact account` Debug/ReleaseSafe 检查均 2/2，transport attempt 计数为 2。
- 正常无故障恢复也经真实文件检查（Debug/ReleaseSafe 均 2/2，组合用例包含 append、commit 和 healthy 三种情形）：已提交的精确 `-0.01` WS 费用经 OKX parser/drain/Owner 重放后，唯一应用数量为 20,000、两侧费用均为 10,000 atoms，无经济故障或 OMS recovery_only；准入完成后接受新的独立 intent，重放从未调用 transport，第二次重开仍保留 digest/数量/费用并重新关闭进程准入。
- 2026-10-04 最终核验：实际 Linux 与 Windows 启动接入已完成。Linux 使用私有 DurableSink(93)，在线输入前完整重放；Windows 恢复 engine decision(91)，绑定独立 execution raw(93)，沿既有 generation 校验的 IPC 逐帧解码、提交并确认。复用保留决策日志的有界逐事实索引，不以 canonical cursor 代替 raw watermark；部分同帧提交只补缺失 Fill，重复完整重放不重复费用，冲突、缺历史、容量耗尽及未完成对账关闭准入。真实文件部分/全部事实及中断 REST 检查 Debug/ReleaseSafe 各 3/3。

- 最终组合命令：`zig test src/main.zig -ODebug --stack 67108864 --test-filter 'OKX ready' --test-filter 'core rejected' --test-filter 'Windows file reopen' --test-filter 'Demo owner' --test-filter 'Demo policy' --test-filter 'response persistence failure'`，Debug/ReleaseSafe 各 9/9。Windows 实际 `--windows-chain-test` 在 Debug（构建时 `--stack 67108864`）与 ReleaseSafe 均 exit 0，包含跨进程恢复与恢复后格式错误账户金额：故障提交后 execution 角色预期非零退出，engine 保存 malformed_amount、OMS recovery_only 与不变经济摘要。Linux 实际入口/C shim ReleaseSafe 编译通过。
- Windows 进程链 ReleaseSafe 曾复现 snapshot reflection 编码读取 canonical 事件未使用数组槽位而失败 SnapshotTooLarge；所有 IPC canonical 发送/接收已统一复用 canonical_event_codec。失败路径先 drain/提交规范故障再返回错误，REST 页辅助解析不拦截原文持久化。格式、diff、父 Spec 未修改检查通过；本票完成仅代表离线安全止损，03–14、完整精度实现及新源码在线资格仍未完成。

- 后续 canonical 模块检查发现旧 happy-path 测试仍假定经济 Fill 拒绝不改变安全 digest。现将缺费用、冲突 Fill 的拒绝放入独立候选 shard，明确断言 OMS recovery_only、故障计数和不变经济摘要，保留主成功路径的幂等/重放断言。shared canonical adapter facts Debug 2/2 通过；未回退持久故障合同。
