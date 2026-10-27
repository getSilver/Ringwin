# 策略独立交付与跨模块集成验收

2026-10-23：用户要求其他部分不阻塞策略完成。归属：[模块地图](map.md)。

## 完成口径

- 策略开发：03–11，Python公开接口、数学正确性、规范事件回放、序列及恢复一致性全部验收。可独立交付，不等待Web、核心或Venue施工。
- 经济资格：12/13，真实数据及样本外证据；缺数据保持未完成。
- 运行资格：14/15及以下真实集成清单；未通过时不得标为已可交易或上线。

测试驱动器只注入版本化合同规定的输入和响应并检查策略输出，不实现另一套权威资金、预留、OMS或账本。复用现有codec与framing，接口未知或冲突记录为具体合同缺口。规范事件夹具通过不证明适配器或核心已正确实现。

## 跨模块验收（pending，不阻塞策略开发完成）

- [ ] 07/08候选展示与显式白名单操作接入现有Web控制面；启用、撤销、版本及过期语义端到端一致。
  - 2026-10-28：08新增 `arbitrage_admission` / `arbitrage_signals` 离线公开合同。调用方须从既有Web ConfigEvent/激活事实投影 `Approval`，按配对方向调用 `Signal.activate` 后重新收集信号；刷新 `Facts` 的分账户资金、总/配对/基础资产/Venue剩余额度与账户品种占用。`Request`只是策略准入建议，尚非Host OrderIntent；真实IntentGroup身份/原子预留映射、Unknown按原身份查证、独立模式资格引用、实时模型与风险原因投影及发送前TTL复核仍须端到端验收。详见[08证据](whitelist-allocation-evidence.md)。
- [ ] I1：真实规范行情、深度/规则投影及Host输入一致；关联[核心03](../cross-venue-core-interface/issues/03-depth-resynchronization.md)。
- [ ] I2/I3：Host完整组、共同准入、竞争资金及周期占用；关联[核心04](../cross-venue-core-interface/issues/04-host-intent-group.md)、[核心05](../cross-venue-core-interface/issues/05-joint-admission.md)。
- [ ] I4/I5：真实VenueAdapter规范化、唯一经济Fill、双IOC及Unknown安全响应；关联[核心06](../cross-venue-core-interface/issues/06-dual-ioc-dispatch.md)。
- [ ] Maker原生Post-only及取消/迟到成交公共接缝；关联[核心07](../cross-venue-core-interface/issues/07-native-post-only.md)。
- [ ] I6/I7、S6-A–P：真实Python Host、checkpoint、日志尾、会话及激活屏障；关联[核心08](../cross-venue-core-interface/issues/08-deterministic-checkpoint.md)、[核心09b](../cross-venue-core-interface/issues/09b-cycle-recovery-activation.md)。
- [ ] I8：周期终结、残余承接、费用更正、资金流及风险锁存与真实权威状态一致；关联[核心09a](../cross-venue-core-interface/issues/09a-cycle-closure-residual.md)。
- [ ] 实际模式、平台及Venue资格逐项留证。现有核心离线证据可以复用，不能当成策略集成已通过。

本清单保留原票的跨模块验收责任，不修改其他会话的票或其状态。部署及真实/Demo交易仍需另行授权。
