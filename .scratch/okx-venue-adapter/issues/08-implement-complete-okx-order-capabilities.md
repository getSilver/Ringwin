# 落实既定 OKX 订单能力与有界调度

Type: task
Status: open
Assignee: Codex
Blocked by: 01, 02, 03, 04, 05, 07
Parent: [产品化接入 OKX Venue Adapter](../map.md)

## Question

如何在既有 OrderIntent、RiskDecision、OrderCommand 与 CapabilityProfile 契约下实现 OKX SPOT/SWAP 的 Limit、Market、GTC、IOC、FOK、Post-only、VenueReduceOnly、原地 amend、获授权 CancelConfirmCreate、非原子 TransportBatch、版本化规范化、限流优先级、稳定错误、发送结果与 Unknown 对账，同时继续执行全部已确认的禁用项？
