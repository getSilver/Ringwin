# 09 实施合同：待确认项与公共验收路径

日期：2026-10-22。状态：用户已批准零残余释放及保留 08 范围；零残余实现已通过离线验证，用户明确保留 09a 待费用更正合同验收，09b/09 保留待验收。
归属：[09 汇总验收](issues/09-cycle-recovery.md)。依据：[权威设计](authority-design.md)第 5–9 节、ADR0017、[S6 恢复合同](../cross-venue-arbitrage/state-recovery-contract.md)。

## 当前源码核对

基线 HEAD：`53a91973`；检查时工作树无修改。

- `src/trading/cycle_occupancy.zig`：64 个周期、每周期最多两个成员；支持检查、建立和校验，没有终结或释放路径。
- `src/trading/trading_shard.zig`：`admitDomainGroup` 在同一候选内建立占用并绑定命令证据；`cyclePinsOrder`、`commandNeedsDispatchFacts`、`checkpointPins` 保留活动周期依赖。`validateSnapshotStateInner` 核对占用事实及配置，canonical digest 包含完整周期记录。
- `src/runtime/demo/demo_authority.zig`：活动周期阻止 Fill 归档；不能为了释放容量直接取消这个保护。
- `src/execution/execution_gateway.zig`：发送证明查询原周期。释放后仍需处理历史命令的证明及迟到事实，不能把已终结周期当成可发送许可。
- `src/runtime/recovery_cutover.zig`：现有 `RecoveryCoordinator.expectedVenueEvidence` 使用固定 settlement asset 和 spot/swap 汇总；订单证据虽覆盖驻留订单，仍不足以证明多账户、多 Asset 周期闭合。
- [08](issues/08-deterministic-checkpoint.md)明确仅完成 checkpoint 基础设施；真实模型运行及确定性待验收，整票仍阻塞 09b。

## 已确认的两项合同

1. **残余释放政策**：建议首版只允许数量精确归零的周期释放。任何非零现货残余仍留原 VirtualPortfolio/账户/Asset 账本并保持占用；永续仓位也必须归零。此方案不实现允许非零尘埃释放的资格，不能据此关闭原票中非零残余承接的验收项。若需要该资格，须冻结按 Asset 的单笔上限、累计上限、最大存续时间及规则版本，另实现不可再花费的残余承接事实。
2. **08 范围**：建议保留既有基础设施范围，先推进 09a；09b/09 的最终验收继续等待 08。若本次要求关闭整个 09，须补齐 08 的真实模型输入更新、冻结公式和算法/依赖版本，以及运行确定性证据；不能以示例 replay 或 codec 往返替代。

用户已明确批准上述零残余政策及保留 08 范围；批准不代表已取得闭合事实或完成实现。09a 验收按这个首版政策执行，非零尘埃承接释放保持关闭。

## 按依赖实施的路径与当前实现

一次只领取一张票：先 09a；08 与 09a 验收通过后领取 09b；最后逐项核对 09 汇总条件。

09a 在同一 TradingShard 权威内增加显式周期终结输入和事实，不建立第二套锁表。输入引用原策略、周期、配置及可核验经济/对账屏障；核心从自己的订单、唯一 Fill 累计、账户经济投影和认证历史验证条件，不信任调用者的 completed 标志。Unknown、待决报告/Fill 差异、费用/资金费覆盖缺口、Suspense、待查历史、残仓或未承接残余任一存在就保留占用。

终结走既有 Owner candidate → journal append → Store commit → 发布顺序，一次释放全部成员键。保留可认证的终结身份和内容，重复不二次释放；旧身份异内容拒绝；迟到经济事实仍由原订单/账户归属和认证历史处理。不得通过清空余额、OMS 累计、唯一 Fill 累计或历史高水位实现闭合。

实现覆盖周期状态与核心事件/trace、TradingShard apply 与账户投影核对、Owner/Store 事务、快照编码与状态校验、canonical digest、历史 pin/归档边界及公共验收入口。journal/state/registry 为 44/48/42，StateDigestV12、SemanticAuthorityDigestV2；不支持旧持久格式的隐式迁移。四 shard 基准仅在经济断言和三条恢复路径一致后重新捕获。

`TradingShard.qualifyCycleClosure` 生成只读资格；`cycle_closed` 核心输入再次从权威状态计算并逐字段核对，绑定原策略/周期、组内容摘要和两个已提交对账根。检查每个账户的完整经济覆盖、待查历史、经济故障、OMS 恢复锁存、订单终态、预留、独立唯一 Fill 累计及对账时间覆盖；现货/永续的 portfolio/exchange 投影均须精确归零。重复同一终结无新事实，异内容拒绝。Gateway 继续只接受活动周期证明，终结身份不能恢复旧命令发送资格。

终结保留原 Record、完整资格和终结 fact；有界驻留活动与终结身份合计最多 64 个，新准入预留终结槽位，达到上限拒绝新周期，不淘汰原占用或历史。尚无终结身份的认证归档回收路径，不能将此容量称为无限生命周期资格。原周期和终结事实均 pin；订单按原命令中的周期身份 pin，重用账户品种键不重新 pin 旧订单。多账户 Fill 归档改用显式账户键，保持独立已应用累计及原经济归属。

费用内容变化沿用当前 canonical Fill 身份合同：同一 Fill 身份不同 fee 是冲突，保留原账本、持久经济故障并保持占用，不能作为新的成交应用。此处只完成失败关闭验收，**没有实现可接受的费用更正事件、成功更正入账或更正后闭合资格**；不得据此宣称原票费用更正能力已经全面验收。非零残余同样只保留原账本和占用，没有开放尘埃承接释放。

09b 在上述核心事实与 08 的真实策略状态之间接通恢复；按账户及 Asset 核对证据，完成 cursor 追赶、新 HostActivationBarrier 和原周期关联。保留原期限、退出锁存及下一意图身份；恢复本身不授予新开仓，不重发历史意图。Keep/Migrate/Rebuild 与 Successor 必须逐项证明经济事实不重置。

## 已有任务约定的测试接缝

- VenueAdapter 公共规范输入 → TradingShard.apply → Owner/Store：报告/Fill 两种顺序、重复/迟到、费用更正、资金费、账户对账与认证历史覆盖；观察账本、唯一经济累计、占用和拒绝原因。
- 同一持久输入路径：Unknown、永续残仓、非零现货余额、未解决引用均拒绝终结；订单终态释放资金仍保留键。完整闭合后竞争组才能重新占用全部键。
- 终结 append/commit、发布前后与 checkpoint/关闭重开：恢复为旧占用或完整新终结，无半释放；重复承接/终结无额外经济结果；容量、溢出和历史回收不驱逐未解决证据。
- 真实 ManagedHost checkpoint/BeginRecovery → 核心权威追赶 → activation：覆盖 09b 各阶段与 S6 向量；真实模型缺失时只记录未验收，不用人工填写私有字段冒充运行证据。

验证命令、实际结果及尚未验收项见 [09a 验证记录](09a-verification.md)。Standards/Spec 双轴复审后的实现与文档一起提交；未部署或下单。
