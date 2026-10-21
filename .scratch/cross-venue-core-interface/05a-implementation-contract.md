# 05a 实现合同提案

Status: accepted for implementation; qualification pending

关联：[05 汇总](issues/05-joint-admission.md)、[05a](issues/05a-multi-account-authority.md)、[05b](issues/05b-joint-admission-occupancy.md)、[ADR0017](../../docs/adr/0017-own-cross-account-groups-in-one-decision-domain.md)。

本提案未授予预算、账户、部署或交易权限，未将任何验收项标为通过。2026-10-21 按当前源码 `a4fda07310640e77c38bc2deb7875def6955e65b` 核对。实现 05 需要依序完成 05a、05b 和汇总验收；不能仅去掉 04 的拒绝分支。

## 当前源码与需要补齐的合同

| 当前路径 | 核对结果 | 实现影响 |
| --- | --- | --- |
| `src/trading/trading_shard.zig`，`account_configuration` | 第二次账户配置返回 `InvalidAccountConfiguration`；余额、经济投影、RiskLease、对账游标均为单账户字段 | 必须分区整个账户权威状态，不能只增加账户列表 |
| `src/portfolio/account_coordinator.zig`，`init`、`allocateLeases`、`riskLeaseEvent` | Coordinator 明确只拥有一个 ExchangeAccount；分配上限取本实例 account/global ceiling 的较小值，转换时将该账户 lease limit 填入 `global_limit_atoms` | 不能据此证明多个账户 Coordinator 的额度总和受同一个全局来源约束 |
| `src/persistence/business_history.zig`，`Origin`、`Key`、`Root` | 每个业务根具有单账户 origin；组身份也通过该 origin 命名 | 双账户组身份不能任意借 A 账户或 account=0 表示，必须明确域级历史来源 |
| `src/execution/execution_gateway.zig`，`sendFromShard`、`sourceOrigin` | 来源和权限复核仍读取 shard 的单账户身份，尽管路由表支持多个账户 | 发送与历史证明必须从已提交命令解析账户，保留 decision stream / portfolio 绑定 |
| `src/trading/trading_shard.zig`，`submitHostGroup` | 完整可信候选当前以 `joint_admission_unavailable` 整组持久拒绝 | 04 的 framing 和身份行为保留；05b 才替换最终业务拒绝条件 |

ADR0017 已接受单 owner 多账户方向；用户于 2026-10-21 明确确认下述决策 A 和 B。按既有依赖顺序实施，常规编码和测试无需再次确认。

## 决策 A：冻结完整部署分配清单

推荐首版使用一份不可变、完整的部署分配清单，由现有控制面配置发布责任持有；不增加动态全局额度服务，不扩展账户 Coordinator 为跨账户交易协调者。

清单包含明确的 deployment identity / epoch、规范内容摘要、全部参与 DecisionDomain / decision stream / VirtualPortfolio、账户 Venue / Environment 绑定、每个账户品种的唯一 owner、每账户每 Asset 的资金切片，以及按同一 Asset 分列的全局上限。首版完整部署集合最多 4 账户、4 个 DecisionDomain、128 个 Asset、500 个账户品种键和 2,048 个账户/Asset/domain 资金切片；不是只截取本 Owner 条目。超出界限的部署配置整体拒绝。每个 Owner 读取完整清单并验证：

1. 全部 `(ExchangeAccount, Instrument)` 新风险入口只有一个 owner；单意图入口使用同一归属检查，不能绕过。
2. 每账户每 Asset 给全部 owner 的切片之和不超过账户预算；同一 Asset 给全部账户的预算之和不超过全局预算，全部运算 checked。不同 Asset 不相加，不做隐式估值或跨账户抵扣。
3. 每份账户 Coordinator 租约绑定清单身份、账户、Asset、目标 domain / stream、版本和有效屏障，额度不得超过其静态切片。账户观察余额不是可重复分配的预算来源。
4. 清单摘要必须匹配外围授予该 Owner 的可信部署配置锚点。把输入自带的摘要重新算对不构成授权；缺失锚点、只提供局部条目、租约来源不符均关闭新增风险。
5. 首版禁止清单热替换、动态扩容和在线重新分配。旧世代尚有租约、Unknown、reservation 或活动周期时，新世代不得因版本更大自动覆盖它；本票不实现退休和额度转移协议。

该信任锚点的产品接入也是实现范围，不能用测试 fixture 或调用方随意填入的 `global_limit_atoms` 替代。若现有控制面发布合同不能承载它，必须记录缺口并保持产品入口关闭；离线完整配置验收不能宣称部署资格通过。实际账户名单与金额不在本轮选择。

备选是新增持久全局额度授予者及退休/重分配协议。它增加权威所有者和恢复责任，超出推荐首版，若选择该方案需另行设计。

## 决策 B：显式域级业务历史命名空间

推荐演进业务来源为显式 tagged scope：单账户来源保留账户语义；多账户来源绑定 `DecisionDomain + decision stream + deployment identity`。域级根下的业务键区分：

- 域级组、策略意图和周期身份。
- 带完整 ExchangeAccount 的订单、命令、ClientOrderId、Fill、资金费、对账和经济事实身份。

跨账户组只有一个域级身份和共同提交屏障；不能复制成两个分别可首次准入的组。Gateway 的来源继续携带真实账户、组合和 decision stream，验证其与域配置、已提交成员命令及历史包含证明一致。来自其他 stream 的相同 command_id 或同 stream 其他账户的证明不匹配。

Owner、Store、核心与 Gateway 在同一规范 scope 上验证历史根连续性。沿用 ADR0011/0013/0014/0016 的先发布历史、再持久提交、后回收；根发布成功而 decision commit 失败只留下孤立对象。Unknown、未闭合经济和活动周期引用保持 pin。

不采用“选第一腿账户作为组来源”或复制同一旧根到所有账户的捷径。新旧持久格式严格区分，不自动将单账户经济状态装入多账户 owner。原单意图 wire 可继续用于明确的单账户配置；多账户新增周期要求完整组，单意图不能开启新周期。

## 状态与容量建议

一个 TradingShard 保留唯一 trace、ShardSequence、decision Writer、组身份和周期表。按账户分区观察状态、经济投影、可用资金、租约、对账窗口、经济故障及历史证据。OMS 仍为 owner 内单一命令生成器，所有记录显式保留账户归属；不嵌套多个可独立发布的 TradingShard。

| 资源 | 建议首版界限及验证要求 |
| --- | --- |
| owner 账户 | 最多 4；至少 3 的公共配置验证 AB/AC 竞争；配置显式声明实际数量 |
| 活动周期 / 品种占用 | 最多 64 周期、128 个两腿占用键；键带账户和品种，不因订单终态自动释放 |
| Instrument / Asset 定义 | 保留 registry 的 125 / 128 上限；账户品种归属清单最多 500 键，每账户资产切片最多 128 |
| OMS 订单 | 保留 owner 全局 1,024 live / 4,096 retained terminal，不按账户复制扩容 |
| 命令与身份 | 保留 10,240 command history、10,240 intent history；组及全部成员的拒绝身份成本必须一起预检，不能按“一个组一个槽”估算 |
| 完整组 | 内部上限仍为 4；本功能首次只准入 2 成员；候选、OMS、trace、journal、pin 均预检最坏完整成本 |
| 历史 pin / trace | 保留 8,192 pin、256 驻留 fact；新风险预留至少 64 pin 与 64 fact 的安全余量；这只是最小保留门槛，单次完整候选成本更大时按实际成本拒绝 |
| 安全事实 | 新风险不能消耗保留余量；撤单、Fill、report、对账仍按各自资源预检。独立安全查证槽与 deferred ingress 不被业务候选覆盖；不得承诺安全流无限容量 |
| 快照 | Store 32 MiB 上限不扩大；编码先计算实际字节再提交，超过上限拒绝。满载快照的真实测量及恢复验证是 05a 验收门槛，不能用结构体大小或空状态替代 |

2026-10-22 的实现及测量见 [05 验证记录](05-verification.md)。上述数量是各资源硬上限，不表示可同时承接全部订单的运行资格；账户经济、周期、日志与历史门槛会更早背压。独立安全空间覆盖经济事实、账本、命令、canonical ingress 与 deferred admission，活动引用不淘汰。

实际采用每未承接订单一条最坏 Fill 的候选预算，spot 最多16条账本、swap最多12条；新风险另留2条经济事实与16条账本，纯撤单不产生新成交义务，减仓新单仍须有真实承接空间。有限 partial Fill 需要维护与对账，不能据此承诺无限安全流。核心实际运行前沿快照和 codec 全字段编码上界共同验证32 MiB限制。

Gateway 的权限证明新增域、配置与周期引用后，原40,960条最坏行不能再装入32 MiB。发送记录总上限修订为 `min(40960, (32 MiB - 1 MiB) / (4 + maxEncodedSnapshotUnknown))`，本版为 **39,210**；accepted与uncertain共用总预算，预留1 MiB给头、历史绑定和latch。只背压新增发送，不截断历史、不增大Store上限，V9拒绝旧格式。这是按实测成本修订容量，不授予部署或吞吐资格。

## 实现和验收顺序

1. **05a 配置及权威分区**：配置锚点、全局切片/唯一 owner 校验；两账户 canonical bootstrap、余额、订单与经济归属经 `TradingShard.apply(CanonicalEvent)` 到 Owner/Store、snapshot/restore/replay 一致。双账户组发送保持关闭。
2. **05a 持久与命名空间**：分别升级实际改变的 core/canonical codec、journal、state、registry、history 和 Gateway 格式；先枚举受影响类型及版本，再编码。当前 journal/state/registry 为 42/46/40，具体新身份以实施时 HEAD 为准，不预占编号。旧格式、缺段、损坏、孤尾及相同 command_id 不同来源均失败关闭。
3. **05b 共同准入**：真实 Host 完整候选整体校验；账户/品种/组合/能力/资金/占用/租约逐腿计算，在单个未发布 candidate 完成所有预留、周期键、风险及命令，再由一个 commit 屏障发布。
4. **05b 错误与恢复**：AB/AC 双到达顺序；100 已占 70 再请求 40 拒绝、30 边界；同组 60+50 拒绝；跨账户不抵扣；重复、冲突、冷历史、最后容量槽及整数溢出。枚举真实 append、commit、发布边界逐项注入故障，核对组身份、账户资金、reservation、占用、命令及 canonical digest。
5. **05 汇总**：逐条填原票证据；Unknown、未闭合经济引用和订单终态均不释放周期。09a 的终结/残余政策保持原依赖；06/07 分别承担 Venue 执行，不以核心准入测试代替。

公共测试接缝沿用已确认权威设计第 8 节和各票条件：真实 Host → 核心 apply → Owner/Store commit，以及 snapshot/restore/replay → Gateway 权限复核；不新增内部私有函数测试作为验收替身。

## 确认记录

用户明确回复“确认这两项推荐方案”。决策 A 的“完整静态部署分配清单作为可验证预算与唯一 owner 来源”和决策 B 的“显式域级历史根和带账户的业务键”均获确认。容量表作为首版实施预算，在实际编码及满载测量后验证，未通过不得关闭 05a。依序实施，不需要另行批准常规编码和测试；本合同不要求部署、清理、真实或 Demo 交易。
