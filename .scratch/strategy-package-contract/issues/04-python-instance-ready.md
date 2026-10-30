# 04：创建 Python StrategyInstance 并无权运行至 Ready

Type: task
Status: resolved
Assignee: Codex
Blocked by: [03 通过 DeployRelease 安装并登记 Python StrategyPackage](03-install-python-package.md)
Parent: [模块地图](../map.md)

## Question

如何从Web运行绑定创建一个真实Python实例，经固定API加载和预热后进入Ready？

## What to build

通过现有Web创建实例绑定，实际加载固定API、校验配置并消费规范事件；展示Ready或具体失败原因。

依据：[策略包与加载合同 v1](01-package-and-loading-contract.md)。仅在所有 blocker 完成后认领；本次发布不代表已认领或取得真实交易/部署授权。

## 完成条件

- [x] Web提交明确的定义、配置内容身份、实例、VirtualPortfolio、DecisionDomain及账户/品种范围，后端校验归属和配置。
- [x] 真实候选Host按批准的包与依赖解析入口，调用validate_config、create、on_event和validate；清洁导入路径，不联网安装依赖。
- [x] 固定API检查输出类型、容量、完整IntentGroup与连续IntentSequence；候选输出不进入交易准入。
- [x] 预热条件由策略合同明确；数据不足、预算耗尽、异常或无效配置不得进入可激活Ready，Web显示具体原因。
- [x] 以最小策略完成无权加载至Ready的公共路径验收，保留真实Host证据；跨实例共存由10票扩展。

## Answer / 实现证据

2026-10-30（Windows 补齐验收）：按用户要求和 [ADR0010](../../../docs/adr/0010-qualify-windows-and-linux-independently.md)，Windows 与 Linux 独立验收；Windows 不以 Linux 通过为前提。本票已在 Windows 路径完成无权加载及资源/进程生命周期验收，状态 resolved，05 可基于 Windows 接手；Linux 资源验收缺口继续保留，不代表 Linux 已通过或任何平台取得生产资格。

### Windows 独立验收

- 实现提交 `10713655`，启动归属修正 `275d700c`。现有认证 Web、ReleaseArtifact、完整签名清点和固定 Host API 保持同一入口；Windows 使用 `.exe` 候选适配器及完全离线签名解释器、stdlib、DLL/扩展和隔离 `_pth` 导入路径，不继承环境秘密或 site packages。
- WindowsFilesystemApplier 复用安装/登记/回滚，使用已 flush 的原子文件指针、服务身份的只读/执行 protected DACL，拒绝所有 reparse point（含 junction）。既有 Windows 节点提供 runtime restart 回调；验收只注入回调，不执行真实服务部署。首次重启失败为 unknown，已有版本失败恢复旧指针，均保留签名登记和无权边界。
- Job Object 在 Host 外由 OS 实施 adapter/Host **每进程 committed memory** 硬上限；批准解释器在 128 MiB Job 中分配 256 MiB 必须实际 MemoryError，才可加载。真实候选回调再以 256 MiB 上限尝试分配 512 MiB，结果 Stopped。Linux 仍采用每进程 RLIMIT_AS 地址空间口径；共享 Host 的多实例预算映射留给10。
- 使用 `PROC_THREAD_ATTRIBUTE_JOB_LIST` 在 CreateProcess 内原子入组，再恢复主线程；仅传递三个 stdio 句柄，不继承 Job 句柄。实测后端在创建返回/恢复前死亡，以及 Ready 后死亡，均由内核回收实际进程；重启不能复用历史 Ready。双轴复审发现的创建至 AssignJob 孤儿窗口已修复并定向回归。
- 有界 pipe 读取兼容 Windows 匿名管道，回调和总预热绝对期限由 Host 外监督；超限终止 Job。诊断超过64 KiB终止整树、保留原因至多2 KiB。真实 Host 死亡、后端 EOF、错误配置、数据不足、事件/内存/时间预算、状态篡改、无权输出和批次等价均有公共 HTTP 向量。
- [平台及硬限制实测记录](../evidence/04-windows-platform.json)：Windows 10 Enterprise LTSC `10.0.17763` x64，安装临时目录与工作树文件系统均 NTFS；Python `3.9.18` / ABI `198912`，固定 Zig `0.17.0-dev.315+5b647b792`。测试 engine payload 与 canonical depth 输入仍明确为合成夹具，不执行凭证访问、交易或实际部署。
- [最终 Windows Host 波次](../evidence/04-windows-host-final.log)：27项，26通过、1项仅针对无效 Linux RLIMIT_AS 内核的检查跳过；含真实包摘要、config摘要、Host PID/generation、cursor、next IntentSequence 和 QSSD，所有候选均 `trading_authorized=false`。
- [Windows Python 全量](../evidence/04-windows-full.log)：`10713655` 全量288项，274通过、14项平台跳过；复审修正后对受影响 Host 全部向量及新增创建期/诊断反向量运行上述27项。另 Windows 签名发布的3项回退/unknown/junction向量通过；[Linux 发布回归](../evidence/04-linux-publication-regression.log) 15项中12通过、3项 Windows 专项跳过，不能视为 Linux Host 资源验收。
- [原生 Windows ReleaseSafe 构建](../evidence/04-windows-build.log) 9/9；本轮不重复全量 Zig 核心压力测试，仅候选适配器 Windows PID 从 HANDLE 改为真实 GetProcessId。既有控制面 `verify_control_plane_release.py` 通过，修改模块 py_compile 通过；Standards 0、Spec 启动窗口修正后复审0。

### 历史交付记录（Windows 验收前）

2026-10-30：实现已交付（初始提交 `1e05071d`，修正至 `a15d016f`），最终资源验收未完成。用户确认本轮先提交实现，04保持未验收；维持 in-progress，不开放05。

### 已实现

- 现有认证Web提供 `POST/GET /api/strategy-instances` 和操作台入口。显式绑定包、配置内容及摘要、实例、VirtualPortfolio、DecisionDomain、账户/品种与预算；匹配后端节点提供的 sealed ownership / canonical input source。配置冲突、恢复冒充初始化、未登记或非当前发布均拒绝；绑定及结果持久化，重启不把历史Ready重建为运行实例。
- 按已批准签名重新认证完整运行时与包，核对安装目录全量清点、不可写权限、manifest identity及登记；拒绝额外代码、链接或篡改文件。签名runtime内的内部 `ringwin-strategy-candidate` 复用 Zig ManagedHost / HostSupervisor 和既有匿名pipe协议，不创建控制面CLI，不构造Gateway。
- 清洁环境及 `-I -S -B` 导入固定API；配置验证、create、on_event、validate及新实例snapshot/restore往返；复用QSSD StrategyStateDigest。规范输入经既有decoder验证并按回调规范化批次，保留完整coverage；同流不同批大小的cursor、序号和摘要一致。
- 固定API校验DTO、声明类型、容量、完整组、归属和连续IntentSequence；候选输出丢弃，无ControlCommand、HostActivated或核心交易准入。私有状态往返必须保持序号及字节，validate不能修正私有状态或进度。
- 回调/总预热在Host外计时，超限杀进程组；Ready后监视实际Python管道EOF，Host死亡、后端断开及关闭保持清理/回收归属。签名内存预算经OS硬限制约束；启动前在批准解释器中实测分配失败，不把setrlimit调用成功当作限制生效。

### 保留的 Linux 平台验收缺口

- 本机为 `4.4.0-17763-Microsoft` 的旧WSL1；实测RLIMIT_AS及RLIMIT_DATA设置1MiB后仍能分配10MB。早期真实Host功能波次曾到达无权Ready，但内存反向向量显示不受限，不能作为资源验收或可激活Ready证据。
- Linux 实现继续失败关闭：批准解释器设置1MiB RLIMIT_AS并分配2MiB，只有实际MemoryError/退出码77才允许加载；当前WSL1因此在启动策略及保存实例前明确拒绝。Windows 预算适配已由上述本轮实现及独立证据补齐，不再沿用历史未实现结论。
- Linux 仍须在真正实施 RLIMIT_AS 的内核上运行完整 Host 资源向量。历史 WSL1 的21项 skip不算通过；本轮 Windows 通过不替代 Linux。此前把“必须先 Linux 验收”当作04/05门槛的实现说明已按 ADR0010 和用户要求更正；Windows 已满足本票条件，05可继续。
- 测试使用真实签名Zig适配器、Python解释器及Host；engine payload和规范depth输入为显式合成夹具，不是live node、Demo、经济或生产资格。未访问凭证、交易或部署。

### 可复查证据

- [最终平台拒绝验收](../evidence/04-platform-gate.log)：23项中2通过、21按硬限制不受支持跳过；真实HTTP签名包加载被拒绝，无实例/Host残留。
- [当前内核硬限制复现](../evidence/04-wsl1-memory-limit.log)：WSL1/Python3.8.10，AS/DATA软硬值均为1048576字节，仍分配10000000字节；这是限制失效证据，不能解释为通过。
- [早期完整功能波次及内存失败](../evidence/04-real-host.log)：20项中19通过、1项内存反向失败；包含真实Host、绑定摘要、QSSD、cursor、next sequence及无权证据，明确保留失败而不报整波通过。
- [真实Host后端EOF及回收](../evidence/04-wsl1-functional-stop.log)：非资格功能验证1/1，通过后端stdin EOF证明实际Python被停止并回收。
- [Linux既有回归](../evidence/04-linux-regression.log)：发布、认证、checkpoint、Host bridge 28/28；既有 `verify_control_plane_release.py` 通过。
- [Windows Python全量](../evidence/04-python-windows.log)：283项，248通过、35按平台跳过；非Windows资源资格证据。
- [ReleaseSafe完整构建](../evidence/04-zig-build.log)：9/9步骤通过，包含现有ringwin和新增签名候选适配器；固定Zig `0.17.0-dev.315+5b647b792`。
- [Zig回归边界](../evidence/04-zig-tests-status.md)：首次 `zig build test` exit 0；后续为单独留档而启动的长时间重复波次按本轮交付范围人工取消，不计通过，原始退出日志保留。核心源码此后未变，候选适配器的最终独立构建通过；这些结果不代替Linux资源验收。
- Standards/Spec双轴复审及修正复审：当前代码阻塞项均0；外部Linux资源验收缺口保留。

