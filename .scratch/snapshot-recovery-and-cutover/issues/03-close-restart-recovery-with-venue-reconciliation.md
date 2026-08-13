# 03 — 以 Venue 对账闭合重启恢复权限

**What to build:** 重启后的 TradingShard 在 snapshot 与日志追平后仍保持 RecoveryOnly，并使用 Venue 的订单、仓位、余额和 margin 事实核对本地权威状态；只有全部不确定性闭合后才回到 Ready，且恢复完成不会自行建立新的 TradingAuthorization。

**Blocked by:** 02 — 从 snapshot 与稳定日志尾部确定性恢复

**Status:** ready-for-agent

- [ ] 含 live、partially-filled、pending/Unknown 订单及非零仓位的恢复轨迹会请求并消费明确身份的 Venue 对账事实；重复事实为 no-op，身份冲突或乱序事实失败关闭。
- [ ] 订单终态、reservation、Portfolio/Exchange 数量、余额、OpenCost、margin、费用、账本和 SuspenseAccount 按现有经济不变量闭合；Venue snapshot 只能核对，不能覆盖本地账本或猜测成交归属。
- [ ] 缺失订单、额外 Venue 订单、Unknown 未决、数量或经济差异会形成稳定 ReconciliationBreak/LatchedSafetyGate，并保留 cancel、对账及合格 Reduce-only 通路，禁止新增风险。
- [ ] 全部恢复事实闭合后范围只从 RecoveryOnly 进入 Ready；原有人工 TradingAuthorization 不因进程重启、gate 恢复或对账完成而自动继承，必须经过新的有效 EnableTrading。
- [ ] 成功、差异、重复、冲突和中途再次崩溃的轨迹在 live/replay 中得到相同恢复状态、gate、订单、经济状态、拒绝原因和 CanonicalStateDigest，且不重发历史副作用。
