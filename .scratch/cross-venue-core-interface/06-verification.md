# 06 双 IOC 执行验证

2026-10-22。实现基线 `dda28b878d3edb29671e75cf17629e21c267f738`；固定 Zig `0.17.0-dev.315+5b647b792`，Windows 本机离线。最终完整回归688/688通过，06离线验收完成。

## 实现与所有权

当前 `Gateway.sendFromShard` 已逐命令路由、复核账户权限，并先提交发送身份再调用 VenueAdapter；两条命令无需等待第一腿回报。没有新增发送器、自动补齐、经济回滚或配置入口，也没有修改持久格式。新增公共接缝验收复用05的多账户 Owner 配置，双 IOC 方向分别为买/卖。

测试中的两侧 Adapter 是明确的离线可控实现，用来确定性观察调用次数、TIF、账户和失败边界。私有事实通过 `VenueAdapter.tryDrain → Gateway.drainFair → Owner.applyAdapterBatch → TradingShard` 回流。真实 OKX 私有协议另由现有 `ingestPrivateWs → tryDrain → Owner` 路径验证；这两段组合证据不声称两家真实 Venue 已完成联合网络执行资格。

`PartialExecutionPolicy.independent` 保留每腿真实结果，不自动创建修复单。策略测试消费者只按每单唯一已应用 canonical Fill 累计量推进：报告累计量不能触发第二次经济动作。对于本票的 place/cancel 情形，非终态的可能未承接量保留全部确认订单数量减已应用量；终态仍保留报告累计中未承接的 Fill。新增对冲上限为 `max(0, 原目标 - 已应用 - 可能量)`，Unknown不能被解释为零。在有旧减仓命令时，核心仍按05的累计义务拒绝越过实际持仓的后续意图。

消费者是验收fixture，不是完整策略实现；其计数/累计游标作为测试中的已保存策略状态复制，真实checkpoint联结与激活资格仍归08/09。本票不改变原目标、预算、期限或授权。

## 覆盖与恢复

- 两侧发送均发生在任何私有报告/Fill之前；第二腿背压、停止和异常不撤销第一腿已发送证据、经济归属、预留或活动周期。
- 发送意图及接受结果的4个append、4个commit边界逐项故障。append失败恢复已提交部分；commit失败留下物理孤尾时，恢复Gateway失败关闭。恢复测试保留原live shard发送资格，避免恢复准入锁掩盖重复发送；接受/Unknown证据和原始证明、账户及client ID保持，已尝试发送不再调用Adapter。
- 05的共同准入全部append/commit切点沿用[05证据](05-verification.md)，本票不重复建立另一套共同提交。
- 第二腿Unknown、暂未找到的unresolved查询及checkpoint恢复保留可能量与周期；按原command身份查证，拒绝重新发送。迟到Fill分别覆盖报告先到和Fill先到、重复及撤单途中成交。显式安全修复不能借尚未证实的持仓穿零；两侧真实Fill承接后，策略在现有周期内提出减仓，已有减仓义务使越界追加整体拒绝。
- 真实OKX原始WS的报告先到、缺失Fill尾恢复及重复由经济消费者核对；归档公共路径的十个部分成交窗口、两种顺序、冷重复和恢复同样核对消费者累计及动作次数。
- 活动域周期继续返回`FillArchivePinned`，09a前不能借06释放引用。归档冷重复使用既有单账户归档公共路径证明，不伪称活动多账户周期已可归档。

| 交接项 | 本票离线证据 | 保留边界 |
| --- | --- | --- |
| I2 | 已共同准入双腿独立发送、部分失败不回滚 | 真实Venue网络/模式资格单列 |
| I4、S6-F | 双账户两种顺序/迟到/重复，真实OKX私有WS，归档恢复不重复动作 | 完整策略与checkpoint联结归08/09/10 |
| I5、S6-G执行侧 | Unknown恢复可能量，原身份unresolved不重发，撤单途中Fill及减仓义务不穿零 | native maker语义归07；真实模型和完整策略恢复归09/10 |

## 实际验证

| 命令 | 结果/日志 |
| --- | --- |
| `python tools/zig-entry.py --zig "D:/Program Files/zig/zig.exe" test src/testing/acceptance/core/dual_ioc_dispatch_acceptance.zig --test-filter "06 " -O ReleaseSafe --stack 536870912` | **6/6**、退出0；`06-core-final.log/.exit`；最后两项复审断言由完整回归覆盖 |
| 同工具运行 `venue_fill_recovery_acceptance.zig --test-filter "OKX raw private fills" -O Debug --stack 536870912` | **2/2**、退出0；`06-okx-private.log/.exit` |
| 同工具运行 `fill_archive_acceptance.zig --test-filter "Owner reclaims ten partial" -O Debug --stack 536870912` | **2/2**、退出0；`06-fill-archive.log/.exit` |
| `zig test src/main.zig -O ReleaseSafe --stack 536870912` | 最终源码 **688/688**、退出0；`06-final-full-suite.log/.exit`；进程已退出，无残留Zig/test进程 |
| scoped `zig fmt --check`、`git diff --check` | 通过，退出0 |

## 资格与复审

Standards与Spec复审均无遗留发现。Spec初审要求补齐奇数append边界恢复、Unknown下安全修复及已占减仓义务检查，均已补入；Standards复审要求补齐消费者正数分支及accepted原始证明深比较，均已补入。复审为源码证据，运行结果单列。

没有部署、真实或Demo下单、外部消息或GitHub同步。未选择真实账户/资金；产品多账户入口继续关闭。既有journal/state/registry为43/47/41，本票不变。离线执行接缝证据不授予任何Venue、Linux运行或生产资格。大栈测试配置不证明部署资源资格。
