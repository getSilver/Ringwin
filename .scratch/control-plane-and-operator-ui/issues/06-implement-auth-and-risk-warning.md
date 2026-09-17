# 实现 OwnerSession 认证与 RiskWarning 确认后端

Type: task
Status: closed
Resolution: 已实现并通过全部测试；见下方 Answer
Assignee: ox-alpha (本会话)
Blocked by: 01, 02
Parent: [构建最小控制面与管理操作界面](../map.md)

## Question

首次口令设置与哈希存储、TOTP 初始化、限时会话签发/续期/失效、单一活动会话策略、
高风险操作 RiskWarning 确认流后端、OperatorRecord 落盘、认证失败限速与 CSRF 基线。

## Answer

已实现（2026-08-23，工作树 `D:\github\Ringwin-control-plane`）：

**`python/owner_session.py`（纯逻辑，可注入时钟）**
- PassphraseStore：scrypt（n=2^14,r=8,p=1,dklen=64）加盐哈希；首版最短 12 字符；
  仅允许初始化一次。
- TotpStore：RFC 6238（SHA-1/30s/6 位，兼容标准验证器）；±1 步窗口 +
  已消费时间步持久化重放防护（清理阈值用注入时钟，修复过真实时钟混入 bug）。
- SessionManager：单一活动会话，token 只存 SHA-256 哈希，滑动 TTL 900s，
  新登录吊销旧会话，支持即时 revoke。
- RateLimiter：连续 5 次失败锁 60s。

**`python/control_plane_web.py`（HTTP 后端，仅绑 127.0.0.1）**
- 路由：/setup、/login、/logout、/risk-warning、/command、/operator-records、
  /totp-secret。
- 会话 Cookie HttpOnly+SameSite=Strict；全部变更端点要求每会话 CSRF token 头。
- RiskWarning 确认流：高风险集合 = enable_trading / de_risk / stop_keep_positions /
  resolve_latch（对齐 CONTEXT.md 高危清单在本波次命令集内的子集）；一次性
  warning_identity 与确切命令载荷绑定，过期（300s）、载荷不匹配或重复使用均拒绝；
  低风险命令携带 warning 字段反而拒绝。
- 确认后经 `control_plane.CommandServer` 签名入队（复用 04 号通道），并写
  OperatorRecord（JSONL：时间、kind、target、warning identity、operator=SystemOwner）。

**`python/verify_owner_session.py`（八阶段失败即停验收）**
rfc 向量 → setup（弱口令拒/二次冲突）→ 登录失败限速 + 错 TOTP → 重放 TOTP 拒绝 +
单一会话策略 → 未认证 401 → CSRF 缺头 403 → 高危缺确认 403 / 非高危警告 400 /
载荷不匹配 403 / 确认后入队且信封 MAC 可验 / OperatorRecord 两条归属 SystemOwner →
注入时钟快进过期 401。输出 `owner_session_acceptance=passed`（exit 0）。

**回归**：`verify_control_plane.py`、`verify_control_projection.py`、
`zig test src\main.zig`（108/108）全部仍通过。

**边界说明**
- TLS/反代归生产部署波次；密钥文件解锁 CredentialStore 的整合同前票口径。
- UI 页面本身归 07/08 号票；本票交付的是可被页面直接调用的后端 seam。

## Comments

- 2026-08-23：实现完成，八阶段验收与既有回归全绿，票关闭。
