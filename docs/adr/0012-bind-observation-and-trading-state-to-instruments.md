---
status: accepted
date: 2026-10-09
---

# 按 Instrument 绑定观察、交易权限和当前仓位

票 04 在每分片 125 个 Venue／产品／Instrument 组合上延续现有公共接缝。
观察登记不创建 OMS 订单或授予发送权限；不同 Venue、产品和品种使用不同
规范 InstrumentIdentity，资产单位仍按共享 AssetIdentity 定义。

InstrumentTradingAuthorization 在当前账户、策略激活与配置版本下明确启停
品种，首次授权要求已激活品种及保证金规则。首次明确 CapabilityProfile 激活
仍可建立初始交易授权；已有选择版本时能力刷新不能重新启用停用
品种；停用保留观察、已有订单和撤单能力。其版本及事实屏障进入发送前证明，
不能用改变真实 Venue capability version 来替代业务选择权限。

行情、保证金规则、仓位、成本与标记价格按 Instrument 查证。风险和账本只
汇总相同单位的货币金额，不跨资产相加数量或用另一品种的行情重估仓位。
产品级 scalar 仅为既有单品种入口的兼容视图；发送前以品种投影为准。

核心保持单写者和无 I/O；Gateway 保留账户／Venue／环境／session 及真实
适配器能力版本绑定，并复核品种授权、规则和保证金事实。观察与账户驻留
容量独立于单条传输消息容量；扩大驻留数组不扩大未验证的私有消息协议。

StateDigestV8 绑定品种授权、保证金阈值和完整经济投影。布局演进升级
journal/state/registry 身份，私有恢复 DTO 升级到 schema 2，旧格式失败关闭。订单、成交及
控制历史归档仍由后续票完成，当前配置与位置容量不代替千单或平台资格。
