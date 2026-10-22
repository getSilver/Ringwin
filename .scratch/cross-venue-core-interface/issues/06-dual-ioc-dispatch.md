# 06：双 IOC 独立发送与部分失败承接

Type: task
Status: resolved
Assignee: Codex
Blocked by: [05 共同准入与持久占用](05-joint-admission.md)
Parent: [模块地图](../map.md)

## Question

双腿共同提交后，如何独立发送并真实保留部分失败、迟到成交与 Unknown？

## What to build

从已共同准入的组经 ExecutionGateway 路由至两侧 VenueAdapter，再由公共私有事件接缝返回核心；两腿 IOC 发送不等待首腿成交。

## 完成条件

- [x] 验证两腿独立发送；第二腿发送失败不撤销第一腿真实发送、预留或成交事实。
- [x] 在提交与各发送边界注入故障，恢复后保留身份、发送证据、可能敞口及预留；Unknown 按原身份查证，不自动重发。
- [x] 通过 ingestPrivateWs/tryDrain 与 TradingShard 公共应用路径覆盖报告先到、Fill 先到、重复、迟到及归档恢复；唯一经济增量不重复。
- [x] 下游策略可从规范事实识别新增成交及在途可能量；测试消费者不因重复事实重复提出对冲。
- [x] 修复仍由策略在原目标和预算内提出后续意图；PartialExecutionPolicy 不冒充自动补齐或经济回滚。
- [x] 覆盖 I2、I4、I5 与 S6-F/G 的执行侧场景；离线适配器证据和各 Venue 实际执行资格分别记录。

## Answer

2026-10-22离线验收完成。当前实现已支持独立发送与持久发送证据，本票补齐公共路径验收及测试消费者，没有新增发送器或改动持久格式。

最终ReleaseSafe **688/688**、定向核心 **6/6**、真实OKX私有WS **2/2**、归档恢复 **2/2**，均退出0；双轴复审无遗留发现。详见[验证记录](../06-verification.md)。

双账户测试Adapter公共回流与真实OKX私有协议为组合离线证据，不能推导真实双Venue联合网络资格。活动周期保持`FillArchivePinned`；冷重复由既有归档公共路径验证。S6-G仅关闭本票执行侧场景，原生maker与完整策略恢复仍归07/09/10。本票没有部署或真实/Demo下单，产品多账户入口和线上资格保持关闭。
