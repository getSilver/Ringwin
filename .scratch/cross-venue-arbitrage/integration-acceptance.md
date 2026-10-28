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
  - 2026-10-28：07已交付 `python/arbitrage_scanner.py` 的完整替换快照及 `display_json` 离线合同，11项公开测试通过；未接入真实Web。已核对 `D:/github/Ringwin-control-plane/python/control_plane_web.py` 的OwnerSession授权、`projection_provider.views()`与 `/api/projection`；现有返回为核心 `ok/shards`，尚无候选schema/路由。继续沿现有Web读模型接入，补齐Host外候选传输、版本/会话、失败撤销与无行情到期刷新，不把候选当权威journal或OrderIntent。详见[07交接](opportunity-scanner-evidence.md)。
- [ ] I1：真实规范行情、深度/规则投影及Host输入一致；关联[核心03](../cross-venue-core-interface/issues/03-depth-resynchronization.md)。
- [ ] I2/I3：Host完整组、共同准入、竞争资金及周期占用；关联[核心04](../cross-venue-core-interface/issues/04-host-intent-group.md)、[核心05](../cross-venue-core-interface/issues/05-joint-admission.md)。
  - 2026-10-28：09新增 `arbitrage_cycle.Cycle.from_admission/start/apply` 和 `Action.encode` 离线合同，复用已有Host单意图/完整组codec。真实Host须以当前激活包络发布完整组，并把后续修复/退出意图关联到**原周期**；现有80-byte意图成员没有策略侧周期字段，不能擅自扩wire或把跟随请求当新开仓。核心实际关联、拒绝响应、独立发送及发送前权限复核仍待公共路径验收。详见[09证据](dual-ioc-cycle-evidence.md)。
  - 08的 `execution_hash` 目前只有身份引用，没有结构化执行参数；09验证同一hash及完整规则/场景摘要，但实际价格/修复/退出预算必须由调用方从已认证的同一执行配置版本解析。内容认证与配置/模型哈希一致性仍须真实接线验收，不以hash相等替代参数内容核对。
- [ ] I4/I5：真实VenueAdapter规范化、唯一经济Fill、双IOC及Unknown安全响应；关联[核心06](../cross-venue-core-interface/issues/06-dual-ioc-dispatch.md)。
  - 09调用方须认证完整原周期 `Facts`：`applied_lots`来自包括归档在内的唯一经济应用量，`economic_complete`绑定报告/成交覆盖；不能将OMS累计或驻留明细求和代入。Unknown需投影原序号/可能量和预留，查询指令接原身份对账；策略主动选择零新增交易动作，超时只升级，不等于取消成功。
- [ ] Maker原生Post-only及取消/迟到成交公共接缝；关联[核心07](../cross-venue-core-interface/issues/07-native-post-only.md)。
  - 2026-10-28：11交付 `arbitrage_maker.Cycle`、报价及真实 `maker_cycle` v2 checkpoint；20项公开测试仅验证Python/codec合同。原生order type2/TIF3复用现有Host编码。`Action.cancels` 是原maker意图序号的取消建议；现有Python order codec没有cancel入口，混合取消/hedge动作拒绝直接encode，真实调用方须映射原核心订单并处理两类建议，不能漏掉取消或把建议当取消成功。报价调用方须认证当前深度、经济引用/实际成交前缀、完整联合成本/失败场景和压力预算。实际取消发送/终态覆盖、迟到Fill、剩余量替换、原生Venue拒绝与模式资格仍须公共路径验收，见[11证据](maker-taker-cycle-evidence.md)。
- [ ] I6/I7、S6-A–P：真实Python Host、checkpoint、日志尾、会话及激活屏障；关联[核心08](../cross-venue-core-interface/issues/08-deterministic-checkpoint.md)、[核心09b](../cross-venue-core-interface/issues/09b-cycle-recovery-activation.md)。
  - 2026-10-28：10交付真实模型/标签/Signal/Monitor/Admission/Cycle的严格v2 checkpoint与恢复；v1兼容保留。Python Host子进程可搬运由实际对象生成的包，但portable模式尚不接受cursor之后的日志尾，明确失败关闭。核心仍须接纳schema version2、验证当前definition/config/依赖、投影连续日志到实际Python接口、无权重放推进序号并抑制输出、核对恢复digest/激活屏障和显式新开仓恢复。机会正式入口须传原 `(strategy_instance,pair_ref,direction)` 与实际触发ShardSequence，不能把grid当ShardSequence。11已用同codec增加独立maker_cycle tag，保存真实报价/取消/在途hedge/预算/目标进度；实际核心接纳该tag、真实旧输出拒绝、持久预留/经济结果、Keep/Migrate/Rebuild及Successor切换仍未运行，详见[10证据](strategy-recovery-evidence.md)及[11证据](maker-taker-cycle-evidence.md)。
- [ ] I8：周期终结、残余承接、费用更正、资金流及风险锁存与真实权威状态一致；关联[核心09a](../cross-venue-core-interface/issues/09a-cycle-closure-residual.md)。
  - 09的 `safe_reduce_lots` 须由当前核心经济状态投影，扣除在途授权及基础币费用；`economic_entry`须携带已完成净收益、当前成本与费用更正。NAV/外部资金流/峰值须同口径，策略的原因锁存须接现有核心安全事实及Signal锁存。`closed_ref`认证当前完整经济/订单覆盖，迟到事实使旧闭合失效时不得复用；现货不足一lot残余须显式承接且保留真实余额/成本，永续余量保持占用。实际核心状态、公共接缝及运行资格尚未运行。
- [ ] 实际模式、平台及Venue资格逐项留证。现有核心离线证据可以复用，不能当成策略集成已通过。

本清单保留原票的跨模块验收责任，不修改其他会话的票或其状态。部署及真实/Demo交易仍需另行授权。
