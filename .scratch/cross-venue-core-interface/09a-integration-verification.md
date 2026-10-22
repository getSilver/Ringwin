# 09a 费用更正与残余整合验证

2026-10-23；主工作树。残余提交 `e72ef437`，费用提交 cherry-pick 后为 `4ab18aab`。冲突仅在公共 acceptance 文件，保留双方 Scenario、spot 判定与费用更正测试；未改 map/issue。

`applyCanonicalFeeAdjustment` 在原有完整身份/费用版本/证据校验及成功入账后，检查原周期已完成的残余。原费用或新费用存在该残余 Asset 的非零金额时，锁存当前账户 OMS recovery-only。费用退款也不能自动成为新周期资金；原残余及原周期身份保持不变。不回滚真实账务，不锁存其他 Asset 的无关费用更正。

公共红测实际观察到费用从基础币 1 atom 更正为 0 后：余额由 1 变 2，原残余仍为 1、原周期身份正确，但 OMS recovery-only 未锁。`.scratch/build/09a-merged-hook-red.log/.exit` 为退出 1 的实际失败证据。新增 hook 修复这一缺口，增加费用的同一场景也保持忠实入账和旧归属。

共享 Asset 支用测试使用同账户 sibling Instrument 103 的更细 lot：1 lot 正好 1 atom；账户原余额正好是已保留的 1 atom，另一腿为正常买入。整个组因 insufficient_spot_asset 拒绝、未占用新周期，证明不同 Instrument 也不能花旧残余，而非仅依赖旧品种本身的粗 lot 阻止下单。

最终定向命令：

```powershell
python tools/zig-entry.py --zig "D:/Program Files/zig/zig.exe" test src/testing/acceptance/core/multi_account_authority_acceptance.zig --test-filter 'retired residual fee' --test-filter 'explicit spot dust' -O ReleaseSafe --stack 536870912
```

最终 **3/3，通过，退出 0**；日志 `.scratch/build/09a-merged-residual-final.log/.exit`。两场景同时经过 Owner/Store、checkpoint、snapshot 与恢复摘要比较；恢复后费用更正 gate 仍锁存，原残余持久保留。费用增减场景在一个公共 test 中分别运行。

CanonicalStateDigest 包含经济投影 digest（含 fee origins/revisions）与 cycles 的规则、配置事实屏障、活动/终结及残余证明；SemanticAuthorityDigest 包含经济 semanticDigest 及同一 cycles 权威字段。journal/state/registry 保持 45/49/43，canonical 16，StateDigestV13 / SemanticAuthorityDigestV3；本次整合不重复升版。

测试文件保留 HEAD 原有 CRLF 风格。两修改文件规范化 LF 后通过 `zig fmt --stdin` 输出逐字节相等检查；`git -c core.whitespace=cr-at-eol diff --check` 通过（沿用仓库文件 CRLF）。新增共享 Asset 组拒绝后复用 Owner.checkpoint 维护原有 journal 容量，未扩大容量、未放松经济或恢复断言。

未跑全量、未更新冻结轨迹摘要、未部署或下单。生产参数默认未配置、承接仅限正 sub-lot；没有已承接残余清理权限。全量与最终双轴审查由主窗口统一执行。
