# 09a 无期限残余复用与人工冻结

基线 `090406e8`，2026-10-23；GPT 6.1 Sol medium 两个子代理在主树协作。用户的 cross-venue-arbitrage 规划改动不在提交范围。依 ADR0019 替代此前期限及永久保留政策，原 717/717 是旧政策证据。

Closed proof 保持不可变；新增有界 Live 投影保留原策略/周期/成员、账户、VirtualPortfolio、Asset、Instrument、承接数量和原事实。当前 remaining、frozen、version 与真实经济消费分配独立维护。未冻结余额可在同账户/组合/Asset 内复用；累计限制求当前 remaining，含冻结及已确认退款 credit，不累加已消费历史。没有最大存续时间或到期停开。单笔初次承接仍是 gross/OpenCost/margin 精确零的正 sub-lot。具体 Asset 和生产额度尚未获批准，规则默认未配置即关闭承接。

真实 Fill/费用驱动 FIFO 消费，行情标记和对账快照不制造消费。消费先用未冻结残余，实际经济扣减如涉及冻结库存，仍忠实入账、记录并锁安全门槛。跨 Instrument 以更细 lot 卖出旧零 gross 库存时保留实际 Canonical/OMS 成交量，用显式库存消费分配转移原 Instrument 归属，不能造 gross 空仓或重复库存。

退款先逆转原消费分配。承接前已付费、承接后退款而没有消费 receipt 的部分，仅在原周期/账户/组合/Asset 唯一原残余 slot 可验证时建立 FeeAdjustment credit 事实，不伪装新周期承接或增加第二份资产。守恒为 original + credit = remaining + 净消费。退款超累计配置仍入账，新增周期受当前额度门槛约束。缺原 slot、歧义、容量不足或真实不足保持失败关闭边界，不能推测资产来源。

人工控制沿用 CorePayload.control_command 的稳定身份、target、版本、期限和已有控制域；新增 freeze_residual/unfreeze_residual，绑定原残余策略/周期/成员、原事实、当前版本及明确数量。解除表示减少 frozen，不删除资产或历史、不清除任何其他安全门槛。冻结拒绝已消费数量及未决卖出/Unknown/未覆盖费用风险；终态报告已到但真实 Fill 尚未扣减的卖出也视为在途。残余状态通过 TradingShard.residualState 查询。现有 Web 到真实 Owner 的签名/投影接线尚未完成，不能将核心 command/query 称 UI 已上线；没有新 CLI、自动补买、兑换或清理。

当前界限：最多128个残余 slot、128个消费来源和32个退款 credit；原活动加终结周期仍64个，不回收原身份。消费/credit 原事实 pin，snapshot 校验余额守恒、冻结命令净额、来源账户/资产、credit 费用修订、gross 外库存销售证明及摘要。journal/state/registry **46/50/44**，StateDigestV14 / SemanticAuthorityDigestV4；canonical16不变。旧格式失败关闭，不迁移，不重捕获冻结轨迹摘要。

## 已观察证据

- 首个公共 manual freeze/release 运行暴露 lifecycle 整体送入4096B摘要 scratch 的 SnapshotTooLarge；改为逐 slot/source/分配摘要，未扩大 Store 上限。
- 后续公共红测分别观察到 domain control scope 不匹配、重复 control 无事实及直接 shard 输入仅进入 cold-history staging；修为 domain 控制目标账户核对、重复幂等及 Owner 全路径验证。
- `09a-owned-freeze-debug3.log/.exit`：公共冻结、重复、Owner checkpoint/recovery、较晚解除 **2/2，退出0**（后续 credit 及完整证明追加之前的局部证据）。
- `09a-owned-freeze-release.log/.exit`：同上加在途卖出拒绝及 append/commit 故障 **3/3，退出0**（后续 credit 追加之前的局部证据）。

- 完整投影承诺补强后，`09a-residual-commitment-green.log/.exit`：公共snapshot篡改来源digest，或同步篡改分配与remaining并重算外层digest，均被拒绝；**2/2，退出0**。
- `09a-owned-control-archive-debug.log/.exit`：真正归档并移除驻留freeze命令、冷证据重复幂等、冻结snapshot/recovery及解除；**2/2，退出0**。
- `09a-owned-final-safe.log/.exit`：更新政策断言后的09a定向及公共State容量测试，**22/22 ReleaseSafe，退出0**。该轮在最后聚合卖单资格修补前完成。
- `09a-owned-economics-final-safe.log/.exit`：完整承诺补强后的经济与人工冻结定向，**6/6 ReleaseSafe，退出0**，同样在最后聚合卖单资格修补前完成。
- 最后修补后，`zig test src/trading/residual_lifecycle.zig -O ReleaseSafe`：**1/1，退出0**；`09a-owned-qualified-final-safe.log/.exit`：**6/6 ReleaseSafe，退出0**。后者包含三个公共经济向量、公共人工冻结归档恢复及State容量边界。

每次生命周期变化追加完整 residual_state_committed 投影承诺并pin最新事实，覆盖来源、FIFO分配、remaining、frozen、version及credit。snapshot核对完整承诺与来源身份，不依赖仍驻留的冻结命令；控制归档后仍可恢复。上文“冻结命令净额”的早期驻留重算实现已由此替代。

容量在112个消费来源时阻止依赖残余的新风险，保留16个有界在途槽；达到128后不造消费证据、不清空或重复入账。除新周期opening外，卖出及改单资格也累计同Instrument已有未应用卖出、同组前项及目标改单承诺，只有需要残余时才用容量门槛，纯gross减仓不一概阻断。State测试经公开add/consume接口实际达到112/128并覆盖聚合卖单判断；Owner另有更早活动周期/Fill/修订/账本容量限制，本记录不声称128来源Owner端到端已验收，也不承诺任意partial Fill无限可入账。耗尽后无足够消费证明的gross-zero实际成交保留原Canonical输入及经济故障，待证未应用，而非声称已经投影。

只运行定向，主窗口统一全量、冻结摘要与双轴复审；未部署、下单或改用户规划。

## Copy / borrowed快照等价回归

主窗口新全量暴露旧copy oracle未规范cycles/lifecycle未用尾部；新Live默认version=1与生产borrowed编码的zero尾部不同。canonicalizeSnapshotState仅该优化test调用，生产writeWithPolicy及摘要常量无需改变。增强同一test污染未用record/live/receipt/credit后，`09a-borrowed-tail-red.log/.exit`实际复现退出1；修复将copy尾部清理与已有borrowed policy对齐，保持逐字节等价和源状态不变断言。`09a-borrowed-tail-green.log/.exit`：同一ReleaseSafe定向 **2/2，退出0**（entry及目标test），三次重复编码均相同，2,342,783字节；未重跑全量或更新冻结摘要。


## 主窗口最终统一验收（2026-10-23）

联合源码 `88b17505`，冻结摘要 `5810f3dc`；首次统一724项发现测试copy快照规范化遗漏新增尾部，已按用户要求停止旧进程，`.scratch/build/09a-reuse-full.stopped` 标明不完整结果，不作验收。修复 `a3e11e72` 保留生产borrowed编码及所有等价断言，独立ReleaseSafe2/2通过。

修复后主窗口独立后台全量：`zig test src/main.zig -O ReleaseSafe --stack 536870912`，**724/724通过，退出0**。日志 `.scratch/build/09a-reuse-fixed-full.log`、退出码 `.scratch/build/09a-reuse-fixed-full.exit`。Python12/12、真实Host集成退出0，见 `09a-reuse-python.log/.exit`、`09a-reuse-host.log/.exit`。

冻结值只在五条轨迹经济/封闭/恢复比较及四分片三路径比较先通过后更新，最终全量已核对新值。15个变更Zig文件规范化换行后与zig fmt输出一致；CRLF-aware diff检查通过。Standards两项恢复认证问题、Spec组合卖单容量绕过均已修复并经静态复查撤回。

当前不设置残余最大存续时间；未冻结残余可供原所有者新周期使用，人工核心控制/查询已验证。Web到真实Owner的签名及投影接线、生产Asset累计数值冻结、真实Venue资格仍未完成。未部署、下单、执行实际冻结/解冻或修改用户另一模块规划。
