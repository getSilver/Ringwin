---
status: accepted
date: 2026-09-06
---

# Linux 生产 role 进程链

## Decision

- 一个签名 RingWin 二进制通过 `--production-role` dispatcher 启动 `engine`、`market-feed`、
  `execution-gateway`、`telemetry` 和 `control-fence` 五个 role；fixture、benchmark 和
  qualification 不属于默认入口，必须使用显式子命令。
- role 之间只使用固定容量 Unix-domain control frame；队列满、非法 frame、断开或 role 缺失均
  失败关闭。TradingShard 不监听公网 socket，也不接收 SecretMaterial；只有 ExecutionGateway
  的 systemd drop-in 允许 Internet address family，实际 Venue 网络仍由后续资格票实现。
- 每个 role instance 使用独立 `ringwin-%i` 用户、runtime directory 和 systemd unit；基础 unit
  启用 `NoNewPrivileges`、`PrivateTmp`、系统目录保护、空 capability 集合和 `AF_UNIX` 限制。
- SIGTERM 先撤销风险授权并进入 drain；在截止时间内返回 stopped，未能完成时输出 forced-stop
  事实。generation 必须递增后才允许重启恢复。
- 当前过程链只贯通 `SimulatedVenue`，不声明真实 Venue、磁盘耐久性或凭证资格。

## Evidence

`--production-chain-test` 在 WSL Linux 原生 ELF 中启动五个真实子进程，验证冷启动、五 role ready、
正常 drain、SIGTERM forced-stop、风险撤销和 generation 3 重启恢复；Windows 只编译和运行离线
状态/队列测试，不建立 Windows service 分支。
