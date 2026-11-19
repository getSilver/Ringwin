# Linux 开发与目标机验证（2026-11-18）

本轮完成 Linux 策略离线验收、文件与凭证基线、进程链失败路径修复。五 role 业务 IPC、
HostSupervisor 接线、签名控制事实、peer credential、持久 generation 和真实业务排空仍未完成；
外部 NodeFence、目标磁盘断电与生产资格未取得。不能把本报告解释为整张生产票完成。

## 环境与身份

- 用户指定 SSH 目标：8.133.180.119，Debian 11、Linux 5.10.0-15-amd64、x86_64、systemd、ext4。
- 内存约 1.7 GiB、无 swap；Python 3.9.2。`prlimit` 的真实分配探针返回内存限制有效。
- 未在目标机安装编译器。Windows 固定 Zig `0.17.0-dev.315+5b647b792` 交叉构建
  `x86_64-linux-gnu` / ReleaseSafe，在目标 Linux 执行 ELF。
- 工作区基点 `22ca6ecac967031a23b78737c3cbba852e3666ff`，包含当时未提交工作；不是该 commit 的干净构建。
- 独立源码快照 343 文件，基础包 SHA-256
  `91dc03580cda02ff4f9186875e758ef837747241dfed49ef2e44aa9872c10765`。
  后续覆盖生产 runtime、策略测试夹具，并补充 UI、进程验收和 memory drop-in。
- 最终 ringwin SHA-256：`9e36dff8494228b8701369de97a20644095391e3060ce91662d6d126f3952faa`。
  [被测文件与三个 ELF 的哈希](../../.scratch/build/linux-20261118/evidence/tested-manifest.json)
  已逐项与本地文件核对。
- 目标工作目录 `/root/ringwin-dev/20261118`；受限 systemd 验证使用
  `/opt/ringwin-dev-20261118/ringwin`。该文件是生命周期修复前的基线 ELF；凭证实现未改变。

## 验证结果

| 检查 | 实际结果 | 证据 |
| --- | --- | --- |
| OwnerSession POSIX 权限与并发 | 5/5 | [日志](../../.scratch/build/linux-20261118/evidence/owner-session-tests.log) |
| 签名策略包发布 | 12 通过，3 个 Windows 专属跳过 | [日志](../../.scratch/build/linux-20261118/evidence/package-tests.log) |
| 策略实例、真实 Host、恢复、授权与配置切换 | 55 通过，16 项按平台/内核条件跳过 | [日志](../../.scratch/build/linux-20261118/evidence/strategy-instance-tests-fixed.log) |
| ProtectedMemory | 5/5 | [日志](../../.scratch/build/linux-20261118/evidence/protected-memory-tests.log) |
| KDF 与保护内存，正常锁内存上限 | 10/10 | [日志](../../.scratch/build/linux-20261118/evidence/credential-kdf-tests.log) |
| KDF 与保护内存，64 KiB 上限 | 10/10，包括拒绝不足预算 | [日志](../../.scratch/build/linux-20261118/evidence/credential-kdf-low-limit-tests.log) |
| fencing 定向 Zig 测试 | 5/5，包括真实目录单 owner | [日志](../../.scratch/build/linux-20261118/evidence/fencing-tests.log) |
| Linux role 控制回归 | 修复前 1 失败；修复后 3/3 | [修复前](../../.scratch/build/linux-20261118/evidence/linux-process-before.log)、[修复后](../../.scratch/build/linux-20261118/evidence/linux-process-after.log) |
| 五 role 生命周期与强停 | 通过，仍为 SimulatedVenue 控制骨架 | [日志](../../.scratch/build/linux-20261118/evidence/process-chain-fixed.log) |
| DurableStore Linux 文件验收 | 通过；注入故障仍在 memory adapter | [日志](../../.scratch/build/linux-20261118/evidence/durable-store-fixed.log) |
| CredentialStore Linux 准入 | 通过，read_only、send_capability=false | [日志](../../.scratch/build/linux-20261118/evidence/credential-store-fixed.log) |
| failover smoke | 15 entries、9 automatic、6 blocked；非真实外部隔离 | [日志](../../.scratch/build/linux-20261118/evidence/failover-fixed.log) |
| 受限 systemd 非 root 凭证测试 | DynamicUser、NoNewPrivileges、PrivateTmp、ProtectSystem=strict、ProtectHome、AF_UNIX、MemoryDenyWriteExecute；32 MiB memlock 成功，64 KiB 失败关闭 | [成功](../../.scratch/build/linux-20261118/evidence/systemd-credential.log)、[不足预算](../../.scratch/build/linux-20261118/evidence/systemd-low-memlock.log) |

systemd 临时 unit 使用 `--wait --collect`，未启用正式生产 unit。未运行交易所下单或读取 Demo 凭证。
没有运行全仓 Zig 测试、性能/容量压力、72 小时 soak、断电或真实双节点隔离。

## 改动与初次失败

- `production_runtime.zig` 拒绝第二次 drain，防止重复命令刷新 5 秒关闭等待；真实 Unix socket
  回归先复现 `G` 而非失败 `X`，修复后进程失败关闭。
- 进程链协调器分别计算已启动 child 与已连接 stream，启动失败时不再关闭未初始化 stream。
- 策略篡改测试在修改字节后恢复 POSIX 只读权限，确保执行字节身份校验，而非先被可写权限拒绝。
- ExecutionGateway 增加 `LimitMEMLOCK=32M` drop-in，覆盖约 19 MiB KDF 工作区和受保护缓冲区。
- 文档补全策略实例测试必须构建的 authority probe，避免把缺少探针误判为业务失败。
- 初始快照遗漏 `operator_ui.html` 造成首页 404；补齐后策略包测试通过。
- 初次策略实例测试缺少 authority probe，并暴露上述夹具问题；补齐与修复后全套通过。
- 默认 8 MiB 栈运行 DurableStore 验收触发 SIGSEGV；测试以 `ulimit -s 524288` 重跑通过。
  受限 systemd 凭证测试另以 64 MiB 栈运行通过，不代表完整业务栈预算已获资格。
- 首次 systemd 测试把二进制放在 `/var/tmp`，被 PrivateTmp 隔离，返回 203/EXEC；改用 `/opt` 后通过。

## 复现

在独立源码副本用固定 Zig 构建：

```powershell
zig build -Dtarget=x86_64-linux-gnu -Doptimize=ReleaseSafe -j2 -p ../install
zig build strategy-authority-probe -Dtarget=x86_64-linux-gnu -Doptimize=ReleaseSafe -j1 -p ../install
```

把 candidate 与 authority probe 放在同目录，再在 Linux 执行：

```sh
ulimit -s 524288
export RINGWIN_CANDIDATE_ENGINE="$PWD/ringwin-strategy-candidate"
export RINGWIN_LINUX_ENGINE="$PWD/ringwin-fixed"
python3 -m unittest discover -s python -p test_strategy_instance.py -v
python3 -m unittest discover -s python -p test_linux_process_chain.py -v
./ringwin-fixed --durable-store-test
./ringwin-fixed --credential-store-test
./ringwin-fixed --production-chain-test
./ringwin-fixed --failover-smoke failover-report.json
```

## 未完成工作

生产地图 [02](../../.scratch/production-readiness/issues/02-run-linux-production-process-chain.md)
仍缺业务 IPC、peer credential、签名控制事实、持久 generation、常驻 HostSupervisor 和真实业务 drain。
Windows 业务 owner 与命名管道、Windows 文件 adapter 绑定，不能直接把平台检查删掉作为 Linux 实现。
本轮只是该票的控制失败路径修复，没有关闭该票。

当前 NodeFence 仍由进程内字段模拟 establish/readBack，没有外部隔离 provider。已向用户索取第二节点和
外部隔离方式，未取得前不能验收真实主备。单机进程终止、目录锁、模拟 smoke 均不替代这项证据。
