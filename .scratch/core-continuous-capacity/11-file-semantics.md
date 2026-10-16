# 11 Linux/WSL1 文件语义与证据边界

本次使用 Windows 固定 Zig `0.17.0-dev.315+5b647b792` 交叉构建 x86_64-linux ELF，并在 Ubuntu 20.04.3 / WSL1 kernel 4.4.0-17763-Microsoft 中实际执行。交叉构建本身不算通过。业务数据、进程中断副本和测试临时目录位于 `/home/ubuntu/ringwin-frontier11`（lxfs），源码和封存日志位于 drvfs；二者不混称 ext4/xfs 目标机。

`11-linux-host.json` 保留发行版、kernel、mount options、CPU/内存、UID/GID、栈限制和两代三字节探针。真实存储设备及驱动的 Linux 拓扑无法由 WSL1 虚拟文件系统取得；主机硬件不作为目标 Linux 磁盘资格。

## 同步与发布

`LinuxFileAdapter` 保持文件同步→同目录 rename→目录同步协议，manifest/snapshot/历史根仍验证 schema、CRC、内容摘要、连续区间与已提交屏障。错误经 Store gate、Owner 和 Gateway 失败关闭；不变更 schema39/43/37 或 artifact identity1。

实际探针 file fsync、same-FS replace、directory fsync 和重开均通过。代码中的 `syncDirectory` 对 IO/NOSPC/ROFS 返回错误；旧 WSL1 目录 fsync 若返回 INVAL/OPNOTSUPP，仍走原有 sync() fallback。实际adapter的旧strace曾暴露O_PATH目录句柄导致EBADF。修复initPath/openPath以Linux-only iterate=true获取可同步目录fd，BADF现在直接失败关闭。普通探针不冒充adapter同步证明，最终另以实际应用seed的strace逐一验证四片及Coordinator目录fsync成功且无sync()回退。探针成功不能证明目标节点耐久性；断电、设备缓存及目标 ext4/xfs 同步资格均未取得。

文件长度原先依赖标准库 statx，旧 WSL1 不支持，真实回归返回 Unexpected。历史私有同步 handle 改用 lseek(CUR/END/SET)，恢复原偏移，所有错误继续关闭；报告的独立只读 handle 同样以 lseek 观察长度。无 objects 时以 no-follow open 检查 roots 是否存在，缺两文件才报告 OrderHistoryUnavailable，已发布根缺 objects 仍关闭。没有将未知错误当作不存在。

## 恢复和故障

复用票10原有公共 Owner/Gateway→Store→snapshot/reopen 夹具、500组合观察/三类别及共享账户。按十轮进程链核对全部报告的权威字段，CanonicalStateDigest 另外绑定完整 snapshot；不使用 economic/semantic digest 代替恢复身份。

故障 hook 返回命名错误，不能称真实 ENOSPC/short-write/timeout；物理截断、缺段、错误摘要及合法 CRC 的错误 schema/artifact 是自有夹具上的真实文件操作。SIGKILL 只作用于编排器创建的 child PID，并在明确的持久应用前后 marker 后触发；不是随机 syscall 中断、跨分片原子事务或断电。

旧 WSL1 主线程 hard/soft stack 均为8MiB；试图提高 ulimit 返回 Invalid argument，直接执行大夹具实际栈溢出。离线 file CLI 使用64MiB显式工作线程。标准测试 runner仅把原 main body 移到256MiB线程，保留原测试遍历、Skip、错误日志和allocator leak检查；固定原始runner与变体SHA见11-test-runner-origin.json。生产role入口和准入不使用该离线线程包装。实际栈峰值未测。

## 资源与未测

旧测试直接把tmpDir目录注入FileAdapter时也必须使用iterate=true；17个Store与2个Owner夹具已同步此合同，不能靠恢复BADF静默回退让它们变绿。

/proc/PID/status每100ms采样直接子进程VmRSS；VmHWM在WSL1为0，按不可用保留，不冒充OS峰值。stat.st_blocks曾对非空文件返回0，也可在内容完全不变时由非零值继续变化；逐文件保留raw_st_blocks和可用allocated bytes，缺项聚合为null。恢复内容身份仅比较路径、长度和SHA，不能把动态分配量当作内容；logical bytes与所有文件SHA仍可检查。队列仅为命令结束时resident样本，瞬态高水位、实际栈峰值、索引成本及apply/commit p99未测。

每个业务夹具跨全部分片live/terminal各不超过100。千单容量、压力、RSS/资源预算、目标平台性能、磁盘掉电、转储保护、真实NodeFence和Linux生产资格均deferred或not_run。WSL结果只交接开发文件功能，不关闭production-readiness专项资格。
