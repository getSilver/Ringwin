# 12 独立平台生产交接及未测范围

本轮封存只表示核心小规模功能范围完成。Windows/Linux任一平台均可独立推进专项；另一平台或本票不是额外准入门槛。没有部署、凭证或Demo/Testnet/生产写授权，所有生产资格仍为false。

## 平台文件功能证据

| 项目 | Windows | Linux/WSL |
| --- | --- | --- |
| 共同业务源码 | 115文件244f3ae7；12当前同源重建/受影响回归与真实进程链 | 同一115文件244f3ae7；11-v6完整两模式及真实进程链 |
| 实际数据文件系统 | 本机NTFS、自有目录；元数据见10 host与12当前OS/命令 | WSL1 Ubuntu20.04.3、kernel4.4.0-17763-Microsoft；业务数据lxfs，源码/封存drvfs |
| 同步/发布功能 | 普通文件flush、replace及重开；历史native probe目录FlushFileBuffers实际error5，未提高权限规避 | 实际adapter四片+Coordinator目录fsync951次成功，零失败/全局sync回退 |
| 崩溃功能 | owned进程在明确持久应用前后终止，恢复完整旧/新authority、accepted/Unknown零重发 | 同样的指定marker与公共业务链，实际ELF在WSL执行 |
| 仍不证明 | 目录flush耐久性、设备缓存、目标磁盘/断电、跨片原子事务、生产资格 | ext4/xfs目标节点、设备拓扑/缓存、断电、跨片原子事务、生产资格；memfd IPC能力明确skip |

## 后续生产工作

| 范围 | Windows后续 | Linux后续 |
| --- | --- | --- |
| 支持合同/准入/ReleaseArtifact | 依据[ADR0010](../../docs/adr/0010-qualify-windows-and-linux-independently.md)独立冻结平台、OS、节点、账户、产品、artifact及配置；现有production dispatcher/报告不自动授Windows资格 | 沿用[Linux生产专项](../production-readiness/map.md)，将当前源码、schema与目标ReleaseArtifact重新精确绑定；旧合同不当作当前已合格 |
| 常驻生命周期/排空/恢复 | 真正常驻业务所有权、服务管理、generation、最小权限IPC、排空与重启；复用已有Windows业务链，但不能重命名VerificationRole冒充生产 | 专项[02进程链](../production-readiness/issues/02-run-linux-production-process-chain.md)、[03真实持久恢复](../production-readiness/issues/03-persist-and-recover-authoritative-state.md)，在目标节点验证 |
| 文件、凭证与转储安全 | 目标NTFS/权限/目录同步/断电故障；密钥准入、内存、最小权限及dump，不能用.env.local或离线Secret测试代替 | 目标文件系统故障、受限fd、内存锁定、secret scan、dump及[04安全准入](../production-readiness/issues/04-unlock-credential-and-pass-security-admission.md) |
| Web操作与发布/遥测 | 复用现有Web控制面；后端鉴权、签名发布、回滚、审计/遥测与资格报告待独立验收 | 专项[08签名发布](../production-readiness/issues/08-operate-and-deploy-signed-release.md)、[09遥测](../production-readiness/issues/09-publish-telemetry-and-build-qualification-report.md) |
| 独立隔离及HA | 真正外部NodeFence、PrimaryLease、主备隔离、网络分区/旧主复活和恢复证据；进程内模拟不是物理隔离 | 专项[10主备切换](../production-readiness/issues/10-fail-over-with-lease-and-node-fence.md)；真实外部NodeFence与目标节点矩阵 |
| 在线Venue | OKX/Binance/Bybit按实际产品、账户、版本独立验证；历史Windows OKX Demo仅保留原资格，不扩大至其他Venue或当前新版本 | 专项05/06/07的OKX Demo、Binance/Bybit Testnet与生产账户重新各自取得证据；离线raw frame/模拟发送不关闭在线任务 |
| 长时和生产准入 | 性能/安全故障合同、72h soak、生产只读影子及另行授权Canary后方可授予限定生产资格 | 生产地图[Route中的11生产资格及Canary](../production-readiness/map.md#route)，相同要求仍待完成 |

仓库旧`production-readiness`及`windows-process-chain-verification`地图中“Linux唯一生产/Windows永久非生产”的历史措辞，按accepted ADR0010解释为已被取代的限制；这不使Windows当前实现自动成为ProductionPlatform。此票不改写旧线上结论、不关闭任何生产专项，也不未经批准创建Windows专项票。

旧Linux地图列有06/07/11，但这些独立票文件不在当前工作树；后续专项执行前须恢复或确认其本地规格。本交接只引用现有地图路由，不把缺失规格当作已完成，也不自动新建或同步GitHub任务。

## 统一未测与deferred清单

- 1024 live/分片、100000完整生命周期、持续/突发速率、千单容量及压力，不执行、不授资格。
- 1GiB/RSS、2MiB生产核心栈、最坏snapshot/复制、瞬态队列水位、物理索引成本、apply/commit p99、恢复/RTO和目标吞吐预算。64/256/512MiB离线/测试栈预留不证明实际栈峰值或生产达标。
- 真实8TiB物理配额、80%/90%阈值、保留期/归档滞后与目标磁盘耗尽、设备EIO/short-write、随机syscall中断及真实目标机掉电。hook验证失败关闭语义，不替代设备故障矩阵或无限存储保证。
- 目标文件系统、最小权限/出口/账户/credential/dump/IPC安全、独立外部NodeFence与HA、在线Venue、72h soak、生产只读影子及资金Canary。

每项未来资格必须重新绑定平台、OS/硬件/文件系统、源码/ReleaseArtifact、schema、Venue/账户/能力及配置哈希。缺证据时仍失败关闭；任何Demo/Testnet或真实资金写入均需当次有界授权。继续使用既有Web控制面，不新建控制面CLI。
