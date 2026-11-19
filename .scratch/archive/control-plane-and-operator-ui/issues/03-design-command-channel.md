# 确定 ControlCommand 注入通道与失联降级设计

Type: grilling
Status: closed
Resolution: 已冻结；见下方 Answer
Assignee: ox-alpha (本会话)
Blocked by: 01, 02
Parent: [构建最小控制面与管理操作界面](../map.md)

## Question

1. 通道形态：TCP、目录投递还是命名管道？谁拉取？
2. 命令信封在通道两端分别由谁校验；幂等如何保持？
3. 控制面失联降级行为；本地紧急 KillSwitch 控制台形态。
4. 与 ConfigEvent 的同构程度。

## Answer

SystemOwner 已确认全部四项决议（2026-08-23）：

**1. 通道形态（A 主 B 辅）**
拓扑事实：四个 TradingShard 同驻一个 Zig 宿主进程，因此是 Zig 宿主代全部分片
统一拉取、按 target 路由。
- 主通道：localhost TCP。Python 控制面监听 127.0.0.1，Zig 宿主作为客户端
  长连接轮询拉取待执行命令；长度前缀帧协议。命名管道双侧成本最高，排除。
- 辅通道：目录投递仅用于 Q3 紧急 Kill 入口，不承担日常流量。

**2. 信封校验分工（两层分离）**
- 通道层：帧级 HMAC 认证（复用 01 号票密钥），防未授权本机进程注入。
- 业务层：信封进入 Zig 宿主后做一次 MAC 验证与过期预检，随后原样交给目标
  分片；权威校验（target、content_hash、expected_version、command_id 幂等）
  全部由分片内 `applyCommand` 在日志内完成。控制面不做业务裁决；
  expected_version 由 UI 从只读投影读取后填入，投影滞后导致的失配拒绝是
  可接受行为，UI 展示失败原因即可。

**3. 失联降级 + 紧急控制台（方案 A）**
拉取模型下失联语义天然干净：连不上控制面 = 没有新命令；交易面按 CONTEXT.md
在既有 ConfigEvent/RiskLease/凭证有效期内继续，Kill/latch 不受影响。
紧急控制台：Zig 宿主额外监视一个本地投递目录；节点上的独立小脚本由
SystemOwner 手工输口令解锁 CredentialStore 中同一 HMAC 密钥，签发
`kill_switch` 命令文件原子投入即生效——与主通道共用同一信封格式与验签路径。
"SystemOwner 直接到 Venue 外部操作 + 事后对账"仍为文档化兜底，两者并存。

**4. 与分片事件 seam 同构**
不新增屏障类型：信封验证后经既有 `applyStable` 写入目标分片日志成为普通
权威事实，重放走同一路径恢复相同摘要；跨分片路由失败沿用
`CrossShardDelivery` 错误语义。唯一核心变更是 `CommandKind.kill_switch`
枚举项及转移规则（等价 KillGate：撤销授权、锁存、需 SystemOwner 解除），
实现归 04 号票。

## Comments

- 2026-08-23：grilling 四问全按推荐冻结，票关闭；fog 中"失联紧急控制台形态"
  毕业并入 04 号票实现范围。
