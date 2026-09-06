# 启动可安全排空的 Linux 生产进程链

Type: task
Status: resolved
Assignee:
Blocked by: [01 冻结首个 Linux 生产合同与 schema](01-freeze-linux-production-contract.md)
Parent: [Linux 生产资格收口](../map.md)

## Question

如何把当前验收可执行入口收口成 Linux 上可启动、隔离、停止和恢复的最小生产进程链，同时不把
网络、凭证或 OS 生命周期泄漏进 TradingShard？

## What to build

使用一个签名 RingWin 二进制的受限 role 启动 engine、market-feed、execution-gateway、telemetry
和 control/fence 进程；各 role 由独立 Linux 用户与 systemd unit 运行。以 SimulatedVenue 贯通
Recovering → Ready → Trading → Draining → Stopped，证明进程身份、有界 IPC、HostSupervisor、
信号处理和 SafetyGate 在真实 Linux 进程中闭合。

## Acceptance criteria

- [x] 默认入口是生产 role dispatcher；fixture、benchmark 和 qualification 只能由显式子命令进入。
- [x] TradingShard 没有公网 socket 或 SecretMaterial；ExecutionGateway 是唯一私有交易网络 owner。
- [x] role 间只使用既定共享内存或 Unix domain socket seam，队列固定容量且背压失败关闭。
- [x] systemd unit 使用独立非 root 用户、明确可写目录、私有临时目录、能力裁剪和禁止提权配置。
- [x] SIGTERM 完成 Draining、撤销授权、排空有界输出并在截止时间内退出；超时形成 ForcedStop 事实。
- [x] 任一必需 role 未启动、异常退出、身份不匹配或 IPC 断开都不能进入或保持新增风险状态。
- [x] SimulatedVenue 的冷启动、正常停机、强制终止和重启恢复集成测试在 Linux 原生运行通过。
- [x] Windows 仍能运行离线单元/契约测试，但不存在 Windows 生产服务分支。

## Out of scope

- 真实 Venue 网络、真实磁盘耐久性、凭证解锁、遥测后端和主备切换。
- 容器编排、服务网格和每个 role 独立二进制框架。

## Answer

已将默认入口收口为显式 production role dispatcher：`--production-role` 只接受 engine、
market-feed、execution-gateway、telemetry、control-fence 五个 role；离线 fixture、benchmark
和 qualification 均必须使用显式子命令。角色之间使用固定容量 8 的 Unix-domain control seam，
非法 frame、背压、缺失 role 和断开都失败关闭；TradingShard 不拥有公网 socket 或 SecretMaterial，
只有 execution-gateway 的 systemd drop-in 允许 Internet address family。

`SIGTERM` 先撤销风险授权并进入 drain；超时或强制终止输出 forced-stop 事实，重启必须递增
generation。systemd 模板启用独立 `ringwin-%i` 用户、runtime directory、PrivateTmp、
NoNewPrivileges、能力集清空和系统目录保护。

## Evidence

- [x] 默认入口为 role dispatcher，fixture 改为显式 `--offline-fixture`。
- [x] Windows Debug/ReleaseSafe 各 `191/191` 通过，Linux 生产 role 不产生 Windows service 分支。
- [x] WSL Linux 原生 ELF `--production-chain-test` 通过：5 roles recovering/ready、SimulatedVenue、
  drain=5、forced_stop=1、`risk_authorized=false`、generation 3 restart、Unix IPC、bounded_queue=8。
- [x] Linux role 交叉编译通过；systemd unit 位于 `deploy/systemd/ringwin-role@.service`。
