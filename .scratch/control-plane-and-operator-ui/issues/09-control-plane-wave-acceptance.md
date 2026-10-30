# 形成控制面整波自动验收

Type: task
Status: closed
Resolution: 已形成单入口整波验收并全部通过；见下方 Answer
Assignee: ox-alpha (本会话)
Blocked by: 08
Parent: [构建最小控制面与管理操作界面](../map.md)

## Question

把各票分散验收整合为一条失败即停入口，补齐矩阵缺口：登录/限速、未认证与 CSRF、
高危确认栅栏、命令幂等生效、四分片定向投递、UI 投影一致、失联降级、重放等价。

## Answer

已实现（2026-08-24）：

**入口**
- `python/verify_control_plane_wave.py`：单进程编排——构建 Zig 探针/节点、
  四分片 genesis 落盘、启动通道服务 + Web 后端 + 演示节点，随后逐阶段断言。
- `tools/verify-control-plane-wave.ps1`：仓库惯例的 PowerShell 包装，
  成功输出 `control_plane_wave_acceptance=passed`。

**八阶段（对应 01 号验收矩阵）**
- A 认证：未认证读投影 401；二次 setup 冲突；错误口令 ×5 → 429 限速。
- B 登录：错误 TOTP 401；正确口令+TOTP 获得 OwnerSession 与 CSRF token。
- C 栅栏：无凭证裸请求 401；有会话缺 CSRF 403；高危命令缺 RiskWarning 403。
- D 命令与幂等：低风险 Pause 生效（Draining→lifecycle progress→Ready）；
  高风险 EnableTrading 经 RiskWarning 流恢复授权；重复 command_id 二次提交
  在核心幂等（版本只前进一位，日志不产生第二事实）。
- E KillSwitch：经确认流打入 shard-2 → effective_authority=false 且锁存 1。
- F 失联降级：关闭控制面监听后节点继续存活 ≥3s，shard-2 日志字节级不变，
  直接重放确认 operator_kill 锁存仍在（Kill 不自动解除）。
- G 重放等价：四份磁盘 journal 直接 SemanticReplay 投影，mode/effective_
  authority/unresolved_latches/operational_version/last_sequence 与服务视图
  逐字段一致。
- H 四分片定向投递：跨分片目标在 Router 处拒绝（CrossShardDelivery），
  不影响任何目标分片；四分片各自独立投影。

**结果**：`control_plane_wave_acceptance=passed`（exit 0）；既有四条验收
（owner_session / channel / projection / operator_ui）与 `zig test src\main.zig`
108 项测试保持通过。

**边界说明**
- 矩阵第 4 条"UI 投影与分片权威摘要一致"由 G 阶段的磁盘重放对账承载；
  CanonicalStateDigest 级对账已在核心波次测试覆盖，本入口不复算摘要。
- 控制面失联阶段以"关闭监听 socket"模拟进程死亡；生产语义（进程崩溃）由
  OS 保证等价。

## Comments

- 2026-08-24：整合入口完成并全绿，票关闭。
