# 01 — 标准化 ControlCommand 与基础交易授权状态机

**What to build:** 在现有 `TradingShard.apply(CanonicalEvent)` interface 内接收有界、版本化、语义幂等的 ControlCommand，闭合 `Stopped → Recovering → Ready → Trading`；只有范围处于 Ready 且全部必需 SafetyGate 开放时，`EnableTrading` 才能建立 TradingAuthorization。

**Blocked by:** None — can start immediately.

**Status:** done

- [ ] ControlCommand 具有稳定身份、明确目标、版本前置条件和有效期限；错误目标、过期、旧版本、前置版本不匹配及身份冲突均失败关闭，语义重复为 no-op。
- [ ] OperationalMode 与 TradingAuthorization 保持正交；未处于 Ready 或任一必需 SafetyGate 关闭时，`EnableTrading` 不得进入 Trading。
- [ ] 未授权的原生或 Python OrderIntent 不进入风险准入，也不产生 OrderCommand。
- [ ] 模式、授权、命令身份及拒绝原因进入稳定日志和 CanonicalStateDigest，实时与 replay 得到相同结果。
