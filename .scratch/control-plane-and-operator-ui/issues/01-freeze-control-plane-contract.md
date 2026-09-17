# 冻结控制面产品闭环与权威所有权

Type: grilling
Status: closed
Resolution: 已冻结；见下方 Answer
Assignee: ox-alpha (本会话)
Blocked by:
Parent: [构建最小控制面与管理操作界面](../map.md)

## Question

在写任何代码之前，冻结本波次的契约：

1. 控制面拥有什么、永不拥有什么？
2. 首版支持哪些 ControlCommand？
3. 命令签名的密钥模型：放哪里，如何轮换与吊销？
4. 验收矩阵需要哪些轨迹？
5. CONTEXT.md 词条沉淀？

## Answer

SystemOwner 已确认全部五项决议（2026-08-23）：

**1. 所有权边界（三句冻结）**
控制面只拥有：①签名 ControlCommand 的产出与投递；②OwnerSession 会话状态；
③分片日志 tail 出来的只读投影缓存。永不拥有任何 Order/Position/Ledger/
RiskReservation 所有权，永不直接写分片内存状态。投影缓存过期或日志缺口时
必须标记 degraded，不得静默展示旧数据。

**2. 首版命令集合**
以分片现有七种 CommandKind 为准：`start_recovery / enable_trading /
trading_pause / cancel_open_orders / stop_keep_positions / de_risk(含
Flatten=target 0) / resolve_latch`。
- 新增 `kill_switch` CommandKind（方案 A）：向后兼容扩展核心 seam，
  控制面可显式签发 KillSwitch；需同步知会交易核心闭环波次地图。
  不借道 GateChange（会污染 margin_kill 等审计语义）。
- DeployRelease / ForwardRollback 划出首版（已记入地图 Out of scope）。

**3. 密钥模型（方案 B）**
HMAC-SHA256 对称 MAC 作为首版"软件签名"实现：密钥由 CredentialStore 式
口令解锁后只驻控制面与分片两进程内存；这是对 CONTEXT.md "软件签名"的显式
窄化，生产化波次再升级非对称签名（Zig 侧已有 Ed25519，Python 标准库没有，
自写 Ed25519 的正确性风险不进首版关键路径）。CONTEXT.md ControlCommand
词条措辞保持抽象不改。

**4. 验收矩阵（五组 + 一条补充）**
① 成功链路：登录→EnableTrading→投影一致→Pause→Resume→重放摘要等价；
② 认证失败：错口令/错 TOTP/过期会话/未认证 API 全拒且限速生效；
③ 命令失败：重复 command_id 幂等、过期拒绝、expected_version 不匹配拒绝、
坏 MAC 失败关闭、缺 RiskWarning 确认的高危命令拒绝；
④ 失联：杀控制面 → 分片按既定策略继续/降级 → Kill 不自动解除；
⑤ 投影失败：日志缺口/未知 schema → degraded 且 UI 显示降级；
⑥ 补充：四分片下命令定向投递到正确分片（已补进 09 号票）。

**5. CONTEXT.md 词条**
新增 [ControlPlane](../../CONTEXT.md)：面向 SystemOwner 的唯一人工操作入口，
签发认证命令、维护 OwnerSession 与 RiskWarning 确认流、从权威日志重建只读投影；
不拥有权威交易状态，投影过期或缺口时显式降级，失联时交易面在既有授权有效期内继续。
ControlCommand 词条措辞保持抽象不动；不新增投影类词条（RebuildableState 已覆盖）。

## Comments

- 2026-08-23：grilling 五问全按推荐冻结，票关闭。
