# 12 整波小规模功能封存证据

2026-10-18。`12-final-v2`同源码Windows补验、最终audit、独立终审及整波证据封存通过，票12与父地图关闭本轮小规模功能范围。

## 共同源码与验证范围

115份源码/构建文件SHA256为`244f3ae77d0978357809cbf99bf850ba89282799a5902323727d54d62c91233d`，与票11最终Linux v6逐项一致。Zig固定`0.17.0-dev.315+5b647b792`；journal/state/registry=39/43/37，Core artifact identity=1，seed=0x20261008。票12没有修改Zig业务源码。

票11已完成并提交：Linux/WSL ReleaseSafe及Debug各623通过、1指定memfd IPC skip、0失败，实际应用/CLI各十轮30进程、84项审计及独立证据包通过。票10的Windows完整624/624保留在历史f1e1a54a源码范围；不改称本轮当前源码完整Windows套件。

`12-final-v2`重新构建Windows app/CLI、分别运行offline-fixture和windows-chain-test、各十轮30个实际业务进程；Native file 8/8、私有成交恢复模块及依赖323/323、两个旧Owner用例各1/1，共333/333受影响Debug检查通过。16个外层阶段退出0，无超时、捕获错误或fatal诊断；2026-10-18 09:51–10:29运行，最终audit通过。121项源码/producer归档、6个PE及消费SHA逐项一致，两个产物各5个实际数据目录重新读取通过，18个Native file故障/拒绝场景通过。app PE预留64MiB，CLI及测试256MiB，实际线程峰值栈和生产预算未测。

共同源码的功能义务、历史源码谱系及每个01–11条目见[覆盖矩阵](12-coverage.md)。Windows目录flush error5与WSL1目录fsync成功不相互替代，不授目标设备掉电、安全、性能或生产资格；独立专项与未测清单见[生产交接](12-production-handoff.md)。

## 中断候选保留

`12-final-v1`已构建两产物，应用离线入口及第0–8轮记录退出0；第9轮stdout/stderr为空且无result，外层没有完成记录，继续时验证进程已不存在，原因未建立。不将它认作完整通过，不覆盖其数据。98项原始元数据/源码包/日志引用及未执行部分见[中断目录](12-interrupted-v1.json)，其SHA256已写入覆盖文档，随覆盖文档哈希纳入最终包。

v2使用独立隐藏进程和新编号，从头重做Windows验证。Linux已完成的当前同源码结果继续精确引用，不重跑；旧失败及有意终止的原始退出状态保持原分类。

## 复现与封存入口

在相同Windows环境和源码树，以新prefix运行`python .scratch/core-continuous-capacity/run-12-windows.py <new-prefix>`，然后`python .scratch/core-continuous-capacity/audit-12-final.py <new-prefix>`及`python .scratch/core-continuous-capacity/seal-12-wave.py <new-prefix>`。拒绝覆盖既有结果；逐命令、PID、时间、构建参数和消费SHA见各result.json。物理数据留在原自有目录，版本控制仅封存元数据、原始日志、源码包及报告。

封存包至少包含identity/workload/samples/faults/summary，另有audit、physical-audits和manifest；历史非零/超时结果包含有意SIGKILL、负向探针与失败候选，不能一概改称通过或真实设备故障。所有资源数据仅为小功能样本，不授容量、压力、资源预算、索引成本、目标性能或生产资格。本轮功能结论不授予生产资格，不部署、不进行真实交易或凭证操作。

## 当前Windows小样本资源

60条命令样本中，应用采样RSS最大462893056 bytes、OS报告peak462897152 bytes；CLI分别276840448/276844544 bytes。全部recover命令耗时应用1.832–4.124秒、CLI1.771–2.578秒，包含文件恢复与JSON，不是apply/commit延迟或p99。主业务数据logical bytes两产物均从6107476增至7920172；500观察组合另有8155156 bytes。队列只有命令末端样本，实际栈峰值、瞬态队列、索引成本和资源预算仍未测。Linux资源保留票11原始口径，不与Windows互相提升资格。

最终审计见[12-final-v2-audit.json](12-final-v2-audit.json)。独立[Standards](12-standards-review.md)与[Spec](12-spec-review.md)终审无剩余P1/P2。

整波包见[summary](12-final-v2-wave-evidence/summary.md)及[manifest](12-final-v2-wave-evidence/manifest.json)，共有3334个原始/历史引用、120条Windows/Linux命令样本；未执行、拒绝与失败按原状态保留。只读[复核脚本](verify-12-seal.py)验证manifest的7个文件、全部3334个包引用、覆盖文档固定SHA及中断目录的98个子引用通过，结果见[封存复核](12-final-v2-seal-verification.json)。本票没有改写任何生产专项状态。
