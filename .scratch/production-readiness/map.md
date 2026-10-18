# Linux 生产资格收口

Status: active

2026-09-27：`main-safety-remediation` 12 已为源码树 SHA-256 `6bb27f1caff605f7db98e0b7ad3d0358b37a568d7e3fe1e31f7513924f72b2e5` 完成离线验收；11 的 ReleaseArtifact 与该实际被测源码身份精确匹配仍待证明。02–10 的目标 Linux、Venue、独立 NodeFence 和资金资格状态不因离线验收而改变。

## Destination

把当前已经通过离线完整性验收的 RingWin 收口为首个可声明 `ProductionQualified` 的 Linux
生产版本。资格只覆盖已冻结的 Venue、产品、账户、ReleaseArtifact、节点与配置组合；任一环境
仍为 `not_run`、`failed` 或 `invalid` 时不得宣称生产合格。

## Definition of done

- 本图负责 Linux 生产资格；Windows 依据 [ADR 0010](../../docs/adr/0010-qualify-windows-and-linux-independently.md)
  独立取得生产资格，双方证据不互相升级。
- 生产运行入口、真实磁盘日志与快照、CredentialStore、Linux 进程隔离、控制命令、签名发布、
  遥测、PrimaryLease、NodeFence 和一主一热备均形成可运行闭环。
- OKX Demo、Binance Testnet、Bybit Testnet 分别留下真实在线资格证据，且生产只读影子与小资金
  Canary 使用对应生产账户重新取得独立资格。
- 目标 Linux 节点通过持久化故障、密钥安全、生命周期、72 小时 soak、HA 故障矩阵和完整性能合同。
- 每份资格绑定唯一 ReleaseArtifact、BenchmarkManifest、节点基线、Venue/ExchangeAccount、
  CapabilityProfile 和配置内容哈希；报告不可变并包含失败及无效运行。
- README、领域规范、ADR、构建入口、运行手册和资格状态与最终证据一致。

## Rules

- 保留当前 `TradingShard`、`CanonicalEvent`、`VenueAdapter`、`MarketFeedAdapter` 和
  `ExecutionGateway` seam；生产工程不得把 Venue 字段、网络或持久化细节泄漏回核心。
- 当前尚未投产的 Windows/开发日志与快照不要求向后兼容；首个生产 schema 一次性切换并拒绝旧格式，
  不实现双读、双写或迁移兼容层。首个生产版本之后仍须保持经济状态连续。
- 性能门槛是合同，io_uring、epoll、libcurl、专用日志线程和同步批次只是 implementation 选择；
  先复用现有能力，只有目标 Linux 实测不达标才替换 seam 后的实现。
- 生产默认使用 ReleaseSafe；只有目标环境完整资格证明必要且安全时才考虑其他优化模式。
- 不同步 GitHub Issues。每次只执行 Frontier 中的一张票，并保留用户无关工作区改动。
- Demo/Testnet 写操作及任何生产写操作都需要当次 SystemOwner 明确授权；批准本地图不授权真实下单。
- 失败关闭优先于 RTO、吞吐和便利；不得用监控、重试或人工确认绕过 SafetyGate、对账或 fencing。
- 复用已经完成的 Web 控制面作为唯一常规人工操作入口；生产工程只补齐后端命令接入、身份验证、
  发布和安全验收，不再建设独立控制面 CLI。

## Route

1. [冻结首个 Linux 生产合同与 schema](issues/01-freeze-linux-production-contract.md)
2. [启动可安全排空的 Linux 生产进程链](issues/02-run-linux-production-process-chain.md)
3. [从真实磁盘日志与快照恢复一个 TradingShard](issues/03-persist-and-recover-authoritative-state.md)
4. [通过 CredentialStore 完成只读安全准入](issues/04-unlock-credential-and-pass-security-admission.md)
5. [在 Linux 闭合 OKX Demo 在线链路](issues/05-qualify-okx-linux-online-chain.md) — blocked by 02, 03, 04
6. [在 Linux 闭合 Binance Testnet 在线链路](issues/06-qualify-binance-linux-online-chain.md) — blocked by 02, 03, 04
7. [在 Linux 闭合 Bybit Testnet 在线链路](issues/07-qualify-bybit-linux-online-chain.md) — blocked by 02, 03, 04
8. [通过现有 Web 控制面完成签名发布与操作生命周期](issues/08-operate-and-deploy-signed-release.md) — blocked by 02, 03, 04
9. [发布生产遥测并生成 Linux 资格报告](issues/09-publish-telemetry-and-build-qualification-report.md) — blocked by 02, 03
10. [以 PrimaryLease 和 NodeFence 完成主备切换](issues/10-fail-over-with-lease-and-node-fence.md) — blocked by 03, 04, 08, 09
11. [取得 Linux 生产资格并完成小资金 Canary](issues/11-qualify-linux-production-and-canary.md) — blocked by 05, 06, 07, 08, 09, 10 and [main 安全与权威状态验收基线](../main-safety-remediation/issues/12-rebuild-safety-acceptance.md)

## Frontier

- 2026-10-08：新增[核心持续运行容量闭合](../core-continuous-capacity/map.md)前置波次，目标为每分片
  1,024 个同时存活订单；先完成合同、轮转、订单/发送归档、经济历史和容量验收，再收口生产业务链。
  当前仅发布计划，未改实现；本波完成也不自动关闭本图任何生产资格票。

- Linux 目标机资格执行已于 2026-09-21 恢复；五 role systemd、Unix socket、SIGTERM、目标 ext4
  强制断电、`mlock`/`MADV_DONTDUMP`/core 排除和 OKX 只读在线链已取得证据。
- 下一阻塞仍是 02 的真实业务 IPC/peer credential/persistent generation、03 的 Engine/TradingShard
  事务恢复、04 的非环境变量凭证注入，以及 05 私有余额观察、恢复身份与 Trace 发送前容量保护修复后的
  Linux 自动买入/清理、live/replay digest 和 QualificationReport 在线复验。
- Binance/Bybit 无 Testnet 凭证，08 的 Web-to-Linux 发布链、09 的目标机 soak/exporter、10 的独立
  NodeFence、11 的 72h/7d/生产账户/Canary 仍未执行，均不得提升为 production qualified。

## Decisions so far

- 2026-10-08：Windows 与 Linux 均可独立取得生产资格。下方历史 Linux-only 决策已被 ADR 0010
  取代；本图保留 Linux 专项范围，Windows 生产工作另行拆分，历史 Demo 结论不升级。

- 2026-09-22：一次明确授权的 Linux Demo 在线复检在可成交价格带内全量买入 `0.00005 BTC`，
  证明身份宽度修复生效，但终态 REST 回补因 Reconciler 未显式重启对账而返回 `invalid_field`；
  独立受限 IOC 清理后恢复零 BTC、零负债、零仓位、零挂单。已修复 `ready` 状态下的显式稳定双读
  重启并通过 Debug/ReleaseSafe `253/253`、Demo ReleaseSafe `63/63`，但未再次下单，票 05 保持开放。

- 2026-09-22：追加授权的 v37 单次复验仍在首个终态 REST 回补返回 `invalid_field`；受限 IOC 买入
  `0.00005 BTC` 后，应急卖出扣费后的 `0.00004995 BTC`，最终恢复零敞口。v37 未通过，票 05 与
  production qualification 状态不变；用户停止清理指令到达后已停止全部远程写操作。

- 2026-09-22：v38 已证明 ready-mode OKX 私有 WS 事实能跨 VenueAdapter canonical seam，但真实
  filled report 后的同笔 canonical fill 在 TradingShard 被重复加入 OMS cumulative 上限检查，触发
  `InvalidFill`。本次授权买单已成交，当前零负债、零衍生仓位、零挂单但 BTC 非零；遵照用户指令
  不自动清理，禁止继续买入，票 05 与 production qualification 保持开放/false。

- 2026-09-23：v39 前离线回归通过主套件 Debug/ReleaseSafe `264/264`、Demo ReleaseSafe
  `111/111`，目标端账户及服务预检通过；但 private stream 就绪后的 SPOT order-history REST
  bootstrap 因 `conflicting_fact` 在下单前失败。最终仍为零敞口且没有新订单；票 05 与 production
  qualification 保持开放/false。

- 2026-09-21：修复 OKX canonical identity 超出既有 `u64` 权威边界、终态先于余额事实导致误报，
  并在 Demo 外部效果前预留 Trace 容量；Debug/ReleaseSafe `252/252`、Demo 独立测试 `62/62`。
  未扩大 Trace/快照 schema，未再次执行 Demo 写入，因此票 05 与 production qualification 状态不变。

- 2026-09-21：SystemOwner 提供 Debian 目标机并授权重启及 OKX Demo 写验收。目标机完成五 role
  systemd 生命周期、ext4 强制断电恢复、secret-memory/core 排除和 OKX 只读在线链；OKX Demo
  价格带恢复后单次受限 IOC 买单已全量成交，但内部私有余额观察返回 `BuyDidNotFillMinimum`，恢复
  清理又暴露 `IdentityOutOfRange`，故未取得自动闭环资格；应急 IOC 清理后账户保持零 BTC、零负债、
  零仓位、零挂单。
  这些证据不替代尚缺的业务 IPC、真实 TradingShard 恢复、Binance/Bybit、Web 发布、soak、
  外部 NodeFence、生产账户及 Canary。

- 2026-09-17：SystemOwner 确认 Linux 线上资格、目标机断电、外部 NodeFence、生产账户与 Canary
  暂缓。并行工作是 Windows 验证运行时，不是 Windows 生产平台，也不是 Windows 生产兼容层；
  证据与票见 [Windows 进程链验证](../windows-process-chain-verification/map.md)。ADR 0002/0003
  与 `permitsProduction()` 保持。Binance/Bybit 活对接因无密钥暂缓；`TestnetQualified` 保持
  `not_run`。Windows 进程链通过不能关闭本图 02–11。

- 2026-09-09：当前源码复审确认对账、ReduceOnly、算术、OMS 幂等、HostActivated 和唯一发送仍有
  P0/P1 缺口；新增[安全修复波次](../main-safety-remediation/map.md)。最终 ProductionQualified/Canary
  必须绑定该波次的最终验收 revision；既有票 02–10 按复审证据补回未完成条件，不复制第二套生产 tracker。
- 2026-09-06：SystemOwner 确认按 11 张本地票落成生产资格收口计划。
- 2026-09-06：票 01 冻结 `src/production_contract.zig`；Linux 是唯一生产平台，目标仅为 OKX、
  Binance、Bybit 的 SPOT 与 isolated linear USDT perpetual；Gate.io/Bitget 禁用；journal/state
  schema 为 8，ReleaseSafe 为默认构建，io_uring 不构成前置架构要求。
- 2026-09-06：票 02 完成单一 role dispatcher、固定容量 Unix IPC、systemd 受限模板和 SimulatedVenue
  原生 Linux 进程验收；SIGTERM drain/forced-stop 与 generation restart 已通过。
- 2026-09-06：票 03 完成 `DurableStore` 双 adapter；Linux 文件 adapter 已通过 WSL 原生 ELF 的三域
  segment、manifest、提交同步、atomic snapshot 和 close/reopen recovery 验收；目标文件系统断电资格待
  节点清单冻结后执行。
- 2026-09-06：票 04 完成 `CredentialStore`；Argon2id/XChaCha20-Poly1305 认证 metadata、
  Observation/Execution 分文件、单向生命周期、Linux 受保护内存和节点/出口上下文校验已贯通；
  `--credential-store-test` 只进入 read-only Ready，目标节点 secret-scan、core dump、真实
  RLIMIT_MEMLOCK 与生产账户资格仍未执行。
- 生产支持候选固定为 OKX、Binance、Bybit 的 SPOT 与 USDT 线性永续；未列能力保持失败关闭。
- Linux 使用同一签名二进制的受限 role 进程与 systemd unit，不为每个 role 建设独立框架。
- 首版 CredentialStore 使用人工解锁的加密文件与锁定内存，不引入 Vault、TPM 或无人值守解封。
- 首版 HA 为一主一热备、外部 fencing authority、无自动 failback，不建设 Raft/etcd 集群。
- 已有 Web 控制面作为 SystemOwner 的唯一常规入口；不重复实现控制面 CLI，本地图只负责把它接入
  签名 ControlCommand、OwnerSession、OperatorRecord 和发布生命周期。
- 2026-09-07：票 05 已补 Linux 原生 OKX acceptance 入口并完成 x86_64 ELF/libcurl 8.21.0/OpenSSL runtime probe；SystemOwner 已授权 DemoLive，但 WSL1 在官方 Demo private WSS `:8443` 的 `establishReady` 阶段返回 `WebSocketTransport`/`SSL_ERROR_SYSCALL`，且 WSL1 无法连接仅监听 Windows 回环的代理，未进入 dispatch、未执行 Demo 写入，仍未取得在线资格。另以 Windows 443 路径完成 Demo 私有 WSS 登录/订阅及受限 place/cancel 清理验收，证明 Venue 功能可用但不替代 Linux 资格。
- 2026-09-07：票 08 绑定现有 `D:\github\Ringwin-control-plane` Web 控制面，控制面提交 `f7ac68d`；补齐签名 ReleaseArtifact 校验、版本目录原子发布、ForwardRollback、生命周期 outbox、OwnerSession/CSRF/RiskWarning 接线和持久命令去重，定向验收通过。目标 Linux systemd/凭证/NodeFence 生产等价验收仍待执行，OKX Demo 资格不因本票升级。
- 2026-09-07：票 09 接入固定容量 per-shard Telemetry、非阻塞 TelemetryPublish、30 秒/5 分钟 observability fail-closed、BenchmarkManifest 和不可变 QualificationReport；WSL 原生 ELF SimulatedVenue smoke 通过并生成报告。目标节点性能、soak、真实 exporter 和生产资格仍未宣告。
- 2026-09-07：票 10 接入可注入 FencingAuthority、1 秒 PrimaryLease/250 ms 续租、ObservationCredential 热备、NodeFence read-back、FailoverAdmission 和不可变 FailoverReport；9 条自动路径连续三次通过，6 类故障保持阻断。真实独立 fencing authority、目标节点故障矩阵和生产等价资格仍未执行。
- 当前可信离线基线为 acceptance schema 2、journal/state schema 8、Debug/ReleaseSafe 各 214 项；
  OKX Demo、Binance Testnet、Bybit Testnet 的当前共享在线状态仍为 `not_run`。
- 2026-09-07：源码复审撤销票 02/03/04/08/09/10 的过早 `resolved`。安全修复提交 `7917079`
  收口 DurableStore 原子更新和完整 manifest 校验、资格报告 passed 推导、Linux fencing token
  持久化及子 role 授权/信号撤销；控制面提交 `b04d942` 收口 TOTP、认证文件和版本链接切换。
  目标节点故障/密钥资格、真实业务 role 链、生产 exporter、外部 NodeFence 和 Web 到节点端到端
  生命周期仍未完成，不能宣称生产就绪。
- 2026-09-09：控制面安全复审收口至 `71e0ba2`；TOTP 消费并发串行化，ReleaseArtifact 版本目录
  绑定完整 manifest，发布指针或旧 runtime 恢复不能证明成功时记录 `unknown`，不得误报活动版本。

## Not yet specified

- 目标 Linux 裸金属节点、文件系统、磁盘/NIC/PHC、网络出口和独立 fencing authority 的实际清单。
- 三家生产 ExchangeAccount、区域 endpoint、允许 Instrument 与最终 AccountSafetyCeiling。
- NodeFence 的生产 adapter 是出口防火墙、Venue IP 白名单控制还是独立凭证吊销。
- 小资金 Canary 的绝对资金上限、最大单笔、日累计风险与人工值守窗口。

这些值必须在对应票执行时由实际节点、账户和 SystemOwner 决策冻结，不能由开发 fixture 推断。

## Out of scope

- Windows 票 06 已[封存 `9939110d` 的限定 OKX Demo 证据](../windows-process-chain-verification/report-demolive-2026-10-03-recovered.json)；
  只读采集器来源单独记录。该结论不授予 Linux、本图 02–11 或生产资格。

- Windows 生产专项实现与验收不在本 Linux 地图范围；Windows 平台可独立取得生产资格，
  但不得把现有验证运行时的 Demo 证据自动升级为 `production_qualified`。
  Windows 进程链验证是独立波次，见
  [Windows 进程链验证](../windows-process-chain-verification/map.md)。
- 当前 Windows 开发数据、PowerShell live 脚本或旧 schema 的生产兼容。
- 未冻结 Venue、币本位、双向持仓、组合保证金、期权、算法单、跨 Venue 净仓或 Smart Order Routing。
- Kubernetes、服务网格、动态插件、通用 REST/WS/auth 框架、第二套控制 UI、独立控制面 CLI 和
  通用工作流引擎。
- Vault/云密钥管理、TPM 自动解封、多 SystemOwner、双人审批、自动 failback 和通用集群选主。
