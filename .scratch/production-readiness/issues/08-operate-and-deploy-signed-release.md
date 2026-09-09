# 通过现有 Web 控制面完成签名发布与操作生命周期

Type: task
Status: ready-for-agent
Assignee:
Blocked by: [02 启动可安全排空的 Linux 生产进程链](02-run-linux-production-process-chain.md), [03 从真实磁盘日志与快照恢复一个 TradingShard](03-persist-and-recover-authoritative-state.md), [04 通过 CredentialStore 完成只读安全准入](04-unlock-credential-and-pass-security-admission.md)
Parent: [Linux 生产资格收口](../map.md)

## Question

如何复用已经完成的 Web 控制面和签名 ReleaseArtifact 闭合启停、暂停、减仓、凭证轮换、发布和
正向回退，而不重复建设控制面 CLI、通用工作流引擎或允许人工确认绕过安全准入？

## What to build

把现有 Web 控制面作为 SystemOwner 的唯一常规操作入口，接到签名且幂等的 ControlCommand、
不可变 OperatorRecord/ReleaseRecord，以及版本目录加 systemd 的受控部署。复用现有页面和交互，
只补齐缺失的后端 seam、鉴权与安全验收。候选版本无交易权限加载，通过检查后完成 Draining、
CutoverBarrier 和 VersionActivationEvent；激活后只允许停单或 ForwardRollback。

## Acceptance criteria

- [x] 盘点并绑定现有 Web 控制面的源码或 ReleaseArtifact、版本身份、部署位置和当前鉴权能力；不复制页面或另建前端。
- [x] Web 只暴露 EnableTrading、Pause、KillSwitch、CancelOpenOrders、DeRisk/Flatten、credential lifecycle、DeployRelease、ForwardRollback 和 failover 等已定义操作。
- [x] 不存在独立控制面 CLI；本地紧急 KillSwitch 是单向安全触发器，不提供恢复交易、发布、凭证或配置能力。
- [x] OwnerSession 只经管理网/VPN 建立并要求主认证与 TOTP；会话有固定最长有效期、服务端失效和安全 cookie/CSRF 防护。
- [x] 浏览器和 Web 前端不持有 MachineIdentity 私钥、TradingCredential 或 SecretMaterial；敏感签名和准入只在受限后端完成。
- [x] ControlCommand 含唯一身份、目标、内容哈希、版本前置条件、签发/过期时间和签名；重复执行不重复产生外部效果。
- [x] ReleaseArtifact 记录源码、精确 Zig、依赖、构建参数、测试结果、schema registry、哈希和软件签名。
- [ ] 生产节点禁止本地编译及联网安装；只加载签名、哈希、批准状态与 allowlist 全部匹配的 artifact。
- [ ] 冷启动任一 ReleaseArtifact、凭证、时间、网络、日志、对账或 SafetyGate 失败都不能从 Recovering 进入 Trading。
- [ ] Pause、CancelOpenOrders、DeRisk、正常停机和 ForcedStop 的外部效果、Unknown 和最终状态符合领域合同。
- [x] 发布激活前失败保留当前版本；激活后故障停止新增风险，ForwardRollback 不回滚经济状态。
- [x] OperatorRecord 不含 SecretMaterial，且不会复制订单、成交或普通读取日志。
- [ ] Web 到 ControlCommand 再到 Linux role 的全部生命周期、超时、冲突命令、重复提交和 KillSwitch 抢占有端到端集成测试。
- [ ] Web 网络断开、刷新、返回按钮、重复表单、过期会话和后端超时不会重复下发命令或把未知结果显示为成功。

## 当前实现与绑定（2026-09-07）

已绑定现有 Web 控制面仓库 `D:\github\Ringwin-control-plane`，分支为
`control-plane-and-operator-ui`，当前安全修复提交为 `71e0ba2`。本票没有复制页面或新增控制面 CLI；现有入口仍为
`python/control_plane_web.py` + `python/operator_ui.html`，OwnerSession 实现在
`python/owner_session.py`，签名分片命令通道在 `python/control_plane.py` 与
`src/control_channel.zig`。

本次补齐 `python/release_lifecycle.py`：

- `ReleaseArtifact` 强制记录源码 revision、精确 Zig、依赖、构建参数、测试结果、schema
  registry、payload SHA-256 和软件签名；manifest、payload 必须位于 release root 内。
- `FilesystemApplier` 使用版本目录、临时文件同步、原子目录/当前指针替换，并把固定的
  `systemctl reload-or-restart ringwin-role.target` 作为 Linux adapter seam；不执行 shell 或
  任意远程命令。
- 候选检查失败或激活失败保留当前版本；激活序列只前进，`forward_rollback` 是新一次发布，
  不回滚经济状态。`LifecycleOutbox` 为 credential lifecycle/failover 生成幂等 HMAC 命令。
- TOTP 密钥只在首次 setup 响应返回，旧的无认证读取端点已删除；认证文件原子落盘并在 Linux
  固定为 `0600`。`current` 改为原子符号链接，systemd 从该链接启动；重启失败恢复旧链接和旧版本。
- 版本目录持久绑定完整 manifest 哈希；候选发布、指针同步或旧版本恢复无法确定最终运行版本时，
  ReleaseRecord 明确记录 `unknown` 及候选 artifact/manifest 身份，不把软链接状态冒充运行状态。
- Web 新增 `/lifecycle` 和 `/api/releases`，DeployRelease、ForwardRollback、credential
  lifecycle、failover 继续使用 OwnerSession、CSRF 和高风险 RiskWarning；分片命令按
  `command_identity` 持久去重。OperatorRecord 只写非敏感精简字段并同步落盘。

## 证据

- `python verify_release_lifecycle.py`：签名/哈希、候选失败保留旧版本、版本目录原子指针、
  ForwardRollback 代次、outbox 签名与敏感字段拒绝通过。
- `python verify_control_plane_release.py`：Web OwnerSession/CSRF/RiskWarning、发布接线、
  identity 冲突和重复 ControlCommand 不重复入队通过。
- `python verify_owner_session.py` 通过；`zig test src/operational.zig -OReleaseSafe` 通过；
  `zig test src/control_channel.zig -OReleaseSafe` 91/91 通过。
- 既有 `verify_operator_ui.py` 在当前工作区仍按旧的“两分片”假设失败：实际投影为四分片；
  本票未修改该无关 fixture，也不以该失败宣称端到端生产资格。

本票完成的是现有 Web 到签名发布/生命周期后端 seam 的本地实现与定向验收。目标 Linux 节点
上的真实 systemd、发布签名密钥、凭证轮换、NodeFence/failover 和完整 Web→Linux role
生产等价矩阵仍须在目标节点执行；票 5 的 OKX Demo 在线资格仍为 `not_run`，不会被本票升级。

## Out of scope

- 重写现有 Web、独立控制面 CLI、第二套控制 UI、通用工作流/任务队列、双人审批、多版本编排器和任意远程 shell。
- 自动恢复旧经济快照或自动反向补偿 DeRisk。
