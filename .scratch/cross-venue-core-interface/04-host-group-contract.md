# 04 Host 完整组入口合同

本合同仅覆盖 [04](issues/04-host-intent-group.md) 的传输、身份校验和拒绝持久化。遵守 ADR0007、ADR0017；共同准入、账户配置与路由资格归 05a/05b，发送归 06/07。

## 输出与所有权

沿用匿名 pipe 的 StrategyOutput message 和 `QSHO` V1 framing（128-byte header、CRC32C）。`output_type=1, schema=1, count=1` 保留原单意图合同；`output_type=1, schema=2` 显式表示一个完整有序组。不能把两条 schema 1 输出拼成组，也不能把半组退化为单意图。

schema 2 的每个成员使用既有 80-byte OrderIntent V1 编码。成员共享 header 的 StrategyInstanceIdentity、source batch、cursor、配置、会话与激活证据，因而不能逐成员指定冲突策略身份。每个成员单独绑定 VirtualPortfolio、ExchangeAccount、Instrument、方向、TIF、Reduce-only、数量与限价；成员序号必须从非零首序号连续递增且不溢出。

传输有界为 2–4 个成员，最大 `128 + 4 * 80 = 448` bytes，不扩大 OMS 的 4 成员容量。H2 首个执行合同仍限定双腿；本票不授予 3/4 成员或双账户共同准入。未知 schema、额外字段、错误 count/长度、CRC、半帧或半组均拒绝。

Python 不能提供 RiskDecision、RiskReservation、OrderCommand、ClientOrderId 或核心拒绝原因。`GroupCandidate.rejection` 由 Zig Gateway 构造，不属于 Python wire payload。核心只接收一个候选，持久化原始完整 bytes；不会逐成员调用单意图风险入口。

## 身份与授权证据

业务键复用 StrategyInstanceIdentity 与首个连续 IntentSequence，全部成员作为一个原子身份集合。完整有序业务内容与配置绑定同一 SHA-256 指纹；会话、batch、cursor、激活是独立授权包络，不创建新业务身份。相同业务内容换用新合法包络仍是重复；变更任意成员内容或成员顺序是冲突。

原始完整包络随 canonical input 进入 stable journal，input digest 和 CanonicalStateDigest 绑定其全部字节。身份历史复用 OMS，快照、stable replay 和业务历史查验沿用现有所有者；没有新增 Python 锁表或第二个权威所有者。

Gateway 验证当前会话、schema registry、活动策略/配置/激活，以及已发布 batch 的精确 cursor 和 100 ms 新鲜度。核心再次验证策略、配置、激活、会话和 cursor 下界。当前单账户核心尚不能认证双账户路由/余额；即使完整组合法，也以 `joint_admission_unavailable` 整体拒绝。不得将此结果解释为路由、风险或发送资格。

## 拒绝与消费

下表中的持久化均以完整 canonical fact group 成功提交为前提。预留、Order 和 OrderCommand 对所有组路径均为零。

| 情形 | 业务身份消费 | 可观察结果 |
|---|---|---|
| 半帧、半组、非法长度/CRC/成员/序号或容量超限 | 无 | Gateway malformed；已交给核心的拒绝作为 StrategyIntentRejected 输入记录 |
| 未知 schema/registry、旧会话、未激活、冲突策略/配置/激活 | 无 | unknown_schema / old_session / unauthorized；不污染当前策略序号空间 |
| 完整且授权有效，但 stale 或错误/过期 cursor | 全部成员一起消费 | 持久 host_output_stale / invalid_cursor；刷新包络不复用这些身份 |
| 合法完整新组，共同准入未实现 | 全部成员一起消费 | 持久 joint_admission_unavailable |
| 完全相同业务身份及内容 | 不再次消费 | 核心无新事实、无新经济副作用 |
| 同身份异内容、重叠组或与单意图身份冲突 | 无新成员消费 | 持久 intent_identity_conflict，保持原身份历史 |
| OMS 身份容量不足 | 无新成员消费 | identity_capacity_exhausted，OMS 进入 recovery-only；禁止部分记住成员 |
| Trace、journal 或持久提交失败 | 无新消费 | 返回容量/持久错误；未提交 candidate 不发布，允许按已提交历史重试 |

旧会话/身份拒绝本身不能重开任何权限。重启不自动重新授权；旧激活和恢复准入仍按既有合同关闭。

## 格式兼容

在 02 的 journal 40 / state 44 / registry 38 基线上，04 使用 **journal 41 / state 45 / registry 39**，追加新的 canonical core payload tag，保留既有 tag 编号。旧持久版本失败关闭，不提供隐式双读或自动经济状态迁移。Canonical Venue 行情 schema 不由 04 再升级。

旧单意图输出继续使用 schema 1 和既有行为；组输出必须显式使用 schema 2。单账户 Demo 调用者遇到组分支明确返回 JointAdmissionUnavailable，不能落入已有发送分支。

## 验收边界

验收经过真实 Python Host pipe、Gateway、TradingShard.applyStable、snapshot/stable replay，以及本地 FileAdapter 关闭重开后的日志与快照恢复。Linux 运行、断电、HA、Venue 路由及真实或 Demo 交易资格不由这些离线结果授予。具体命令、结果与审查见 [04 验证记录](04-verification.md)。
