# 关闭波次并沉淀证据

Type: task
Status: closed
Resolution: 波次已关闭；见下方 Answer
Assignee: ox-alpha (本会话)
Blocked by: 09
Parent: [构建最小控制面与管理操作界面](../map.md)

## Question

汇总整波证据并关闭本图：README 更新、CONTEXT.md 词条核对、地图决策补齐、
下一候选波次声明。

## Answer

全部完成（2026-08-24）：

1. **README（中英）**：新增"控制面与管理操作界面 / Control Plane and Operator UI"
   章节——能力概述（签名命令通道、只读投影、OwnerSession）、整波验收入口
   `tools\verify-control-plane-wave.ps1`、成功输出行，以及明确"不证明生产部署资格"
   的边界声明与地图链接。
2. **CONTEXT.md**：ControlPlane 词条已在 01 号票沉淀；核对 ControlCommand/
   OperatorRecord/RiskWarning/OwnerSession 既有词条无需改动。
3. **地图**：Decisions so far 补齐 01–10 全部票据结论；Not yet specified 清空
   （失联控制台→04 落地、OperatorRecord→JSONL 落地、刷新机制→1s 轮询、
   PrimaryLease 呈现→07 号 IA 的 gates 表）；Out of scope 维持不变。
4. **下一候选波次**（仅声明，不展开）：
   - 生产部署资格：Linux systemd、TLS/反代、CredentialStore 口令解锁集成；
   - 非对称签名升级（Ed25519）替换首版 HMAC MAC；
   - 单活热备切换的操作界面（含 PrimaryLease 呈现深化）。

**最终证据链**
- `tools\verify-control-plane-wave.ps1` → `control_plane_wave_acceptance=passed`
- `python python\verify_owner_session.py` → `owner_session_acceptance=passed`
- `python python\verify_control_plane.py` → `control_plane_channel_acceptance=passed`
- `python python\verify_control_projection.py` → `control_projection_acceptance=passed`
- `python python\verify_operator_ui.py` → `operator_ui_acceptance=passed`
- `zig test src\main.zig -O ReleaseSafe` → 108/108；fmt --check 全绿

## Comments

- 2026-08-24：波次关闭。
