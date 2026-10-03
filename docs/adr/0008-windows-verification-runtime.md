---
status: accepted
date: 2026-09-17
---

# Windows 验证运行时合同

Windows 是 `ProductionProcessChain` 的验证运行时，不是 ProductionPlatform，也不是 Windows
生产兼容层。本 ADR 不取代、不重开 [ADR 0002](0002-linux-production-support-contract.md) 或
[ADR 0003](0003-linux-production-process-chain.md)。`permitsProduction()` 在 Windows 验证成功
后仍必须为 false。

## Decision

- 唯一允许的本波宣称是 `WindowsProcessChainVerified`。不得把 Windows 验证写成生产层、
  生产兼容层、`production_qualified` 或 Linux 生产资格。
- Windows 验证入口冻结为 `--verify-role` 与 `--windows-chain-test`。Linux
  `--production-role` / `--production-chain-test` 在 Windows 上继续失败关闭，不得被验证入口
  替换。
- 五个 `VerificationRole`（engine、market-feed、execution-gateway、telemetry、
  control-fence）名称可与 `ProductionRole` 对应，但它们不是 `ProductionRole`。IPC 为 Named
  Pipe 加 controller 用户 SID 与精确进程 PID 校验；generation 来自磁盘单调计数。
  engine 的 `owner_ready` 只表示进程所有者初始化，交易 `ready` 要等真实 Host 握手及
  HostActivated 屏障完成。telemetry 对每次 Demo 发送前的存活探测须应答，否则停止发送。
- Windows `DurableStore` 与 `CredentialStore` 是 verification adapter：文件同步使用
  `FlushFileBuffers`，锁页使用 `VirtualLock`。它们不满足 Linux ADR 0004/0005，不得宣称
  power-loss 或 `mlock`+`MADV_DONTDUMP` 等价。
- Demo/Testnet 证据不能升级生产行。Binance/Bybit 活链保持 `not_run`，不得由 Windows 验证
  写成 `TestnetQualified`。
- 本波业务验证只用 OKX `VenueAdapter` 与 `MarketFeedAdapter`。原 `SimulatedVenue` 五进程结果仅是
  历史生命周期回归，不能输出 `WindowsProcessChainVerified`。engine 拥有 TradingShard、
  HostSupervisor 和决策状态；execution-gateway 独占 Gateway、OKX VenueAdapter 与 Demo transport；
  market-feed 拥有 OKX MarketFeedAdapter。telemetry 与 control-fence 须有可验证的职责和失败关闭条件。
- 证据分别记录 `offline`、`read_only`、`demo_live` 的 `not_run`、`blocked`、`failed` 或 `passed`。
  只有三者均通过，且跨进程 role 所有权、持久化恢复和最终账户对账均通过，才可声明
  `WindowsProcessChainVerified`。证据绑定源码 revision、Demo 环境、OKX、账户范围、产品、策略与配置；
  离线与只读结果不证明真实成交，未执行和失败不能写成通过。
- `zig build windows-okx-offline`、`windows-okx-readonly` 与显式授权的 `windows-okx-live`
  分开运行；机器报告记录当前 revision、源码树 SHA-256 与 acceptance/journal/state schema，
  跨模式合并必须匹配同一源码快照；在线只读与真实下单必须匹配账户指纹。历史 Demo 成交保留为来源证据；源码变更后须复测，
  不可从历史 JSON 或手写布尔值授予新版本资格。
- 资格绑定不可变的执行源码快照；只读采集器是独立证据来源。若执行成功而报告解析失败，
  可保留原失败报告，对同次封存存储进行无发送恢复并通过权威只读查询补证。
  补充报告分别记录执行 revision/源码树哈希与采集器 revision/源码树/脚本/二进制哈希，
  校验三模式执行身份一致、存储文件集合及哈希未变、完整 DispatchProof 命令身份、
  canonical Fill/费用、真实订单终态与零敞口。补证只授予原执行版本资格；采集器修改及
  后续运行时源码不继承该在线资格，原解析失败保持 failed。
- 仓库根目录被忽略的 `.env.local` 只为限定 Demo 子进程提供凭证输入。真实下单、再次尝试或清理
  仍需当次 SystemOwner 明确限定账户、产品、数量或名义与截止时间的授权；凭证存在不授予交易权限。

## Consequences

构建、运行输出、README、CONTEXT 与资格工具必须使用同一套词汇。Windows 进程链通过不能关闭
production-readiness 票 02–11。后续 Linux 生产资格仍由 ADR 0002/0003 与 Linux 目标机证据
持有。
