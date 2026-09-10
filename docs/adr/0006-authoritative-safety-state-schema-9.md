---
status: accepted
date: 2026-09-09
---

# 权威安全状态切换到 schema 9

主安全收口为 OMS 增加意图幂等证据、权威剩余数量占用、显式对账终态、完整订单语义和终态墓碑；这些字段会改变日志与快照的经济含义。因此 journal/state schema 从 8 一次性切换到 9，SchemaRegistryId 从 6 切换到 7，并取代 ADR 0002 中关于 schema 8 的冻结；旧格式继续失败关闭，不增加双读、双写或迁移层。
