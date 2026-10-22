# 09a 零残余周期终结验证

日期：2026-10-22。基线：`53a91973`。Zig `0.17.0-dev.315+5b647b792`，Windows x86_64，Python `3.9.18`。

用户批准首版仅精确零残余释放，非零继续占用，并保留 08 基础设施范围，09b/09 待验收。本记录只覆盖该首版核心闭合路径，不代表完整策略、真实 Venue 或部署资格。

## 实现与公共接缝

- `src/trading/trading_shard.zig`：只读 `qualifyCycleClosure` 与 `CanonicalEvent.core.cycle_closed`；核心重新核对原周期、两个账户的已提交对账根、完整经济覆盖、终态订单及唯一 Fill 累计、预留和精确零仓位。
- `src/trading/cycle_occupancy.zig`：一次删除两个活动成员，保留原周期及终结身份；重复无副作用，冲突拒绝。活动与终结身份合计最多 64 个，准入预留闭合身份空间，不驱逐未解决引用。
- Owner/Store：复用候选、append、commit、发布顺序。一个终结输入对应一个持久事实，分别注入唯一 append 和 commit 故障；checkpoint 发布失败时恢复完整已提交终结。
- Adapter 测试边界：外部适配器夹具 `VenueAdapter.tryDrain → Owner.applyAdapterBatch → TradingShard.apply`，不声称验证了真实 Venue 私有协议翻译。覆盖报告/Fill 两种顺序、重复、零残余退出、资金费、两个完整账户对账窗口和连续下一周期。
- 现货退出后 gross 数量归零但基础币返佣剩一个原子时仍保留占用；永续残仓同样不释放。资金费保留在原账户经济投影。
- 多账户 Fill 归档使用 decision-domain root 加显式账户键；归档不改变 portfolio/exchange 经济投影，归档后迟到重复 Fill 不重复记账。关闭重开、journal/checkpoint 重放保持摘要和归属。
- 旧订单按命令的原周期判断 pin；闭合后同一策略的新周期可重用两键，旧驻留订单不会阻塞该新周期闭合。不同 StrategySuccessor 的完整运行联结仍归 09b，不能把此测试称为 Successor 验收。
- 所有匹配账户品种的驻留订单先检查安全闭合，再跳过已经终结的旧周期。旧命令迟到 Unknown 会使新周期预先生成的资格失效；测试经新身份终态对账解除 Unknown，并更新账户经济窗口后闭合，不能仅凭旧终结身份忽略 Unknown。

## 验证结果

| 命令 | 结果 |
|---|---|
| 首次 `zig test src/main.zig -O ReleaseSafe --test-filter '09a zero residual'` | 预期红：核心没有 `cycle_closed` 输入 |
| `zig test src/trading/cycle_occupancy.zig -O ReleaseSafe` | 容量/身份保留测试 1/1，通过 |
| `python tools/zig-entry.py --zig "D:/Program Files/zig/zig.exe" test src/testing/acceptance/core/multi_account_authority_acceptance.zig --test-filter 'conflicting fee correction' -O Debug --stack 536870912` | 2/2，通过；`.scratch/build/09a-fee-debug.log/.exit` |
| 同公共入口 `--test-filter '09a zero residual' -O Debug --stack 536870912` | 迟到旧命令 Unknown 及旧资格失效先红后绿，最终 2/2；`.scratch/build/09a-late-unknown-red.log/.exit`、`09a-late-confirmed.log/.exit` |
| `python -m unittest discover -s python -p 'test_strategy*.py'` | 12/12，通过 |
| 首轮 `zig test src/main.zig -O ReleaseSafe --stack 536870912` | 706/707；09a 八项均通过，唯一失败为旧格式五条轨迹冻结摘要，经济及 stable replay 比较已通过；`.scratch/build/09a-full-suite.log/.exit` |
| 同命令最终完整回归（含迟到 Unknown 修正） | **707/707，退出 0**；`.scratch/build/09a-accepted-full-suite.log/.exit` |
| `python tools/zig-entry.py --zig "D:/Program Files/zig/zig.exe" run src/testing/integration/strategy_host_integration.zig -O ReleaseSafe --stack 536870912` | 退出 0；两账户 GTC/Post-only 文件恢复、Host 完整组及既有单意图路径通过；`.scratch/build/09a-host.log/.exit` |

64 MiB 栈运行在已有大状态候选调用链中溢出；最终采用此前 06/07 验收使用的 512 MiB 测试栈。此配置不证明生产栈、内存或容量资格。新格式 journal/state/registry 为 44/48/42，StateDigestV12 / SemanticAuthorityDigestV2；旧持久格式失败关闭，不提供迁移。

四 shard 原摘要 `81ffd50bc20e9846dd17fdd674956e18f2c9e75d7bcd8a73e31532b1d3afc6e0` 在新摘要合同下变为 `1750cdd35997d0e3e6d0cf472d83e49663ceb7383523f50155008ae5fc6851ef`。重新捕获前，经济断言及连续/三条恢复路径的逐 shard 和共享摘要比较均通过；最终 707/707 完整回归核对了更新后的冻结值。

五条单 shard 轨迹也在原有经济数值、sealed barrier 与 stable replay 相等断言全部通过后重新捕获；新值见 `src/testing/support/trading_shard_fixture.zig`，原始输出见首轮完整日志。只更新固定预期值和版本注释，没有放松经济断言或恢复比较。

## 审查与未完成边界

### Standards

静态复审未发现遗留规范或可确认的正确性问题。归档复用账户视图、scopedKey、Owner 事务及 Gateway 业务根承接；未另建状态来源。有界身份保留有 `shortcut:` 注释及容量测试。

### Spec

旧周期成员混淆和绕过 adapter 测试边界两项发现已修正；多账户 Fill 归档沿用同一账户/根所有权。费用冲突失败关闭已补公共测试。成功费用更正及非零承接仍是验收边界，不将它们报告为已通过。

追加复审确认旧周期终结后迟到 Unknown 的安全缺口：提前跳过旧周期会错误接受下一周期的旧资格。公共红测实际观察到错误 `cycle_closed`；修复为先检查所有相关驻留订单的安全状态，再按原命令周期分组。最终定向及完整回归均通过；新终态对账使用独立身份及证据，不能用被去重的旧终态报告解除 Unknown。

**成功的费用更正入账及随后闭合仍未实现/验收。** 用户进一步明确「保留09a待验收，后续确定更正身份和证据合同」。同 Fill 身份不同 fee 当前返回 `ConflictingFillIdentity`，持久增加 `economic_fault_count`、锁存 OMS recovery-only，原经济投影及占用不变。这能证明安全拒绝，不能替代更正成功路径；09a 的该项保持待验收，整票不据此关闭。

非零现货残余留在原账户/VirtualPortfolio/Asset 投影，未承接时不能释放，没有尘埃承接释放能力。活动加终结身份达到 64 后停止新增周期，终结身份认证回收未实现；未取得连续运行容量、真实 Venue 网络或生产资格。08 模型、09b 激活联结及 09 汇总均保持原依赖，不以本轮离线实现解除；未部署、下单或同步 GitHub。
