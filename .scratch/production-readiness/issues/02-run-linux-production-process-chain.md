# 启动可安全排空的 Linux 生产进程链

Type: task
Status: in-progress
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
- [ ] role 间业务数据尚未贯通；当前 Unix domain socket 只承载生命周期控制帧，队列固定容量且背压失败关闭。
- [x] systemd unit 使用独立非 root 用户、明确可写目录、私有临时目录、能力裁剪和禁止提权配置。
- [ ] SIGTERM 已在子 role 撤销授权并完成 Draining；真实业务输出排空仍待业务链接入后验证，超时形成 ForcedStop 事实。
- [ ] 测试协调器能因缺失 role/IPC 断开而失败关闭；常驻 HostSupervisor 尚未接入生产 role。
- [ ] SimulatedVenue 尚未真正贯通五个 role；当前 Linux 原生测试只证明进程生命周期、授权、超时强停和 generation 重启。
- [ ] 每个 role 的 Unix control socket 校验唯一 controller 的 peer credential；控制命令必须对应已验证的签名事实，首个可访问连接不能仅凭连通性取得授权。
- [ ] generation 来自单调持久状态并在每次重启前递增；systemd 固定常量或进程内计数不能形成恢复资格。
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

### 目标机执行（2026-09-21）

- Debian 12/systemd 252 目标机以五个独立 `ringwin-*` 用户启动全部 role；Unix socket 均为各自
  用户所有、模式 `0700`，只有 execution-gateway 拥有 Internet address family。
- 修复监听 `accept()` 阶段 SIGTERM 无法退出后，整组 stop 均为 `inactive`、`Result=success`、
  `ExecMainStatus=0`、`NRestarts=0`；systemd security exposure 为 4.4/4.6。
- unit 已保持 disabled/inactive。业务 IPC、controller peer credential、签名控制事实、持久 generation、
  HostSupervisor 与真实业务 drain 仍未实现，因此本票不关闭。

### 目标机复检与控制失败路径修复（2026-11-18）

Debian 11/Linux 5.10 上重新执行当前工作区 ReleaseSafe Linux ELF；五 role 生命周期通过。
新增真实 Unix socket 回归先复现重复 drain 刷新关闭等待，修复后 3/3 通过；协调器启动失败清理
分别按已启动 child 与已连接 stream 计数，避免关闭未初始化 stream。

目标机策略实例验收执行 55 项通过、16 项按平台/内核条件跳过，文件、凭证和 KDF 定向验证通过；
ExecutionGateway 增加 32 MiB memlock drop-in，并在 DynamicUser 受限 systemd 临时服务验证。
详见[报告与原始证据](../../../docs/research/2026-11-18-linux-development-validation.md)。
本轮没有接通五 role 业务 IPC、peer credential、签名控制事实、持久 generation、HostSupervisor
或真实业务 drain；本票保持 in-progress，不提升生产资格。

### 单机启动与对端身份（后续验证）

- systemd 为每个 role 提供独立的持久状态目录。role 持有全生命周期独占文件锁，在监听前以
  文件同步、原子替换及目录同步推进 generation。遇到损坏的记录或并发实例会拒绝启动。
- Unix socket 通过 `SO_PEERCRED` 检查身份。夹具限定同用户的父进程 PID，systemd 入口暂以
  root 为操作系统控制主体，仅允许生命周期操作。正式 controller 的进程身份绑定和签名控制事实仍待接入。
- Debian 11 原生 Debug ELF 的进程回归 5/5 通过，五 role 生命周期测试通过。同名 systemd
  临时 unit 以 DynamicUser 两次启动，观察到 generation 从 1 推进到 2，两次完成控制 drain/stop。
- 五 role 业务 IPC、HostSupervisor 和在途业务排空仍待实现。真实主备隔离验收暂缓。

### 2026-11-19 单机离线业务复检

- Debian 11 上使用 Zig 固定版本交叉构建的 Debug ELF 运行 `--production-chain-test` 通过。
  五进程通过 Unix IPC 传递行情、fencing token、订单及成交。Engine 内真实 Python Host 通过
  HostSupervisor 握手并生成意图。进入 Draining 后撤销 Host 权威，执行进程排出两笔合计
  10 手的成交，Engine 提交并验证磁盘重放摘要，telemetry 核对成交数量后完成停止。
- 进程控制回归 5/5。原始日志见 [linux-business-v3.log](../../build/linux-20261118/evidence/linux-business-v3.log)。
- 此路径是显式 SimulatedVenue 验收。systemd 业务启动接线、签名控制事实、在途业务中断后的
  跨重启恢复与正式部署资格仍待验证，票保持 in-progress。
