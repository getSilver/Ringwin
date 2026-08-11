# 实现 Zig 拥有的共享内存 IPC

Type: implementation
Status: resolved
Blocked by: 01
Parent: [产品化接入 Python StrategyHost](../map.md)

## Question

如何以最少产品代码实现两条有界 SPSC、稳定 batch framing 和 Python 原子桥，
并证明跨进程可见性、wrap-around、满/空、损坏与进程退出语义？

## Done when

- Zig 创建、初始化、拥有并回收共享内存与 acquire/release 游标。
- Python 只通过冻结桥访问游标和槽位，不依赖 RawValue 的未证明内存序。
- 可运行检查覆盖双向传输、序号、CRC、wrap-around、满/空、旧映射和损坏失败关闭。

## Activity

- 2026-07-31：已认领；实现前以已冻结 StrategyHostAtomicBridge、线级 schema 和
  失败关闭轨迹为唯一产品契约。
- 2026-07-31：新增 `src/strategy_host_ipc.zig`；Zig 在 Windows 创建可继承匿名
  File Mapping，在 Linux 创建可继承匿名 `memfd`，并独占映射初始化、失效和回收。
- 2026-07-31：两条有界 SPSC 使用按 cache line 分离的单调 `u64` producer/consumer
  游标；producer release 发布、consumer acquire 观察，`publish_many` 校验并复制
  全组后只发布一次游标，不存在部分 frame 可见状态。
- 2026-07-31：实现冻结的五操作 cdecl ABI；Python 只能持有 `QshHandle*` 并执行
  每方向一次有界复制，不取得共享内存指针、slot、游标或进程间锁。
- 2026-07-31：桥在复制/发布前验证 mapping layout、session、长度、batch/Shard
  序号连续性、CRC32C、50 ms 单调时钟新鲜度及 output 基础 framing；损坏使对应
  ring lifecycle 失败关闭，旧 generation 返回 `SESSION_EXPIRED`。
- 2026-07-31：`zig test src\strategy_host_ipc.zig -O ReleaseSafe` 通过，覆盖双向、
  满/空、wrap-around、批量原子发布、旧映射和 CRC 损坏后持续关闭。
- 2026-07-31：`zig run src\strategy_host_ipc.zig -O ReleaseSafe` 通过真实父子进程
  handle 继承与双向可见性，输出 `self_check=ok, cross_process=ok`。
- 2026-07-31：Linux `x86_64-linux-gnu` 交叉编译通过；Windows `.dll` 由 Python
  `ctypes.CDLL` 加载并确认 `qsh_abi_version() == 0x00010000`；原交易引擎三项
  ReleaseSafe 回归全部通过，本票 resolved。
