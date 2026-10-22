# 04 — 在恢复 fence 后追赶 StrategyCheckpoint

**What to build:** 将已发布的稳定 StrategyCheckpoint 恢复到无交易权限的 StrategyHost，并把 StrategyCursor 从 checkpoint 追赶到 TradingShard 的恢复 barrier；追赶期间重新计算的 intent 只用于确定性验证，只有 checkpoint、日志和核心状态全部等价后，策略才具备等待核心显式授权的资格。

**Blocked by:** 02 — 从 snapshot 与稳定日志尾部确定性恢复；03 — 以 Venue 对账闭合重启恢复权限

**Status:** done

- [x] 按 StrategyCursor 从新到旧选择最近一份已经发布且可验证的 checkpoint；容器长度、schema、CRC/hash、StrategyInstance、定义/参数版本、next IntentSequence 和 PortableStrategyState 不匹配时拒绝该 candidate。
- [x] 从 `checkpoint cursor + 1` 连续重放至核心 recovery barrier，验证最终 StrategyCursor、next IntentSequence 和 StrategyStateDigest；缺口、陈旧 session、超前 cursor、输入损坏或摘要不等时保持策略无授权。
- [x] 恢复与 catch-up 阶段产生的 OrderIntent/IntentGroup 只进入 VerificationReplay 比较，不再进入风险、OMS、journal 或 Venue 发送路径；追赶同一历史不会消耗新的 intent identity。
- [x] 核心 Venue 对账未完成、OperationalMode 非 Ready、SafetyGate 关闭或策略尚未追平时，StrategyHost 即使 checkpoint 合法也不能产生可交易输出。
- [x] 原生与 Python 策略共享相同 barrier、cursor、fencing 和恢复结论；有效 checkpoint、损坏最新 checkpoint 后回退到较早版本、追赶失败及成功轨迹均有确定性验收。
