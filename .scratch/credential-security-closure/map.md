# 凭证保护与清零修复

Status: active

## Destination

修复 c5f73ba0 当前审计发现的撤销回退、敏感内存/KDF/签名/传输副本及凭证注入缺口。
规范见[修复规格](spec.md)。原始审计及合成复现见 `../credential-security-audit-20261018/`。

## Definition of done

- 同身份/版本撤销后不可通过 stage、旧配置或并发状态更新复活；失败关闭且保留原文件。
- 模块管理的明文、口令、KEK、KDF 工作区在受控保护内存中驻留，释放前显式擦除，不依赖 allocator 的 undefined 填充。
- 输入、签名、请求和网关进程使用已确认公共 seam 证明错误路径清理与凭证分离。
- 定向回归日常执行；冻结后一次完整离线 Debug/ReleaseSafe、应用/受影响独立入口、独立 Standards/Spec 审查。
- Windows/Linux 功能证据分列；目标机 dump/掉电和生产资格不由本轮自动取得，不连接真实 Venue。

## Rules

- 用户2026-10-18已明确授权直接修复、验证并提交；公共测试 seam 已确认，详见spec。
- 单一集成分支 `codex/credential-security-closure`；实现任务独立分支/工作树，完成后合入集成分支。
- 不更改已封存容量波次证据；旧资格只属于旧源码，新的源码必须取得自己的回归证据。
- 不读取真实密钥、不执行网络请求或订单、不部署；不创建额外控制面CLI。
- 每个实现者一次认领一张可执行Frontier；并行任务不得同时修改同一源码文件。
- 不修改生产平台合同来虚构准入，`admitExecution` 的生产 out-of-scope 继续失败关闭。

## Route

1. [封闭凭证生命周期覆盖与并发回退](issues/01-close-lifecycle-overwrite.md) — resolved；已合入集成分支
2. [建立受保护缓冲与可清零密码学工作区](issues/02-protect-secret-and-crypto-workspaces.md) — resolved；已合入集成分支
3. [贯通凭证存储的保护内存与安全输入](issues/03-integrate-protected-store-and-input.md) — resolved；已合入集成分支
4. [清理认证与传输副本](issues/04-protect-auth-and-transport-copies.md) — resolved；已合入集成分支
5. [贯通网关受控凭证注入](issues/05-bind-gateway-credential-ownership.md) — resolved；定向接入证据已集成，独立审查与最终验收留06
6. [最终冻结、回归与独立审查](issues/06-seal-offline-security-evidence.md) — implementing；依赖已完成，待审查修复后冻结
7. [保护 AEAD 子密钥与显式工作区](issues/07-protect-aead-workspaces.md) — resolved；已合入集成分支并贯通store
8. [保留原生 Demo 账户前后验安全门](issues/08-preserve-native-demo-account-guards.md) — resolved；完整只读guard及独立验收已集成

## Frontier

- [06 最终冻结、回归与独立审查](issues/06-seal-offline-security-evidence.md)

## Decisions so far

- 2026-10-19：05最终 `56b97b92` 已快进合入；[05身份清单](05-validation.json)中726项源码/依赖/producer/归档/产物/日志引用SHA核验通过。v2同源9个新阶段通过，5个v1阶段以输入闭包一致明确复用、保留原身份，不重标为当前源码；详见[05证据](05-evidence.md)。已知 `verify-okx-demo-wave.ps1` CaptureOutput后读取未设置的旧LASTEXITCODE问题保留为06单一review fixer待办，05结案不代表此工具或全任务已通过。当前唯一Frontier为06，先独立双轴审查/修复再最终冻结验收。
- 2026-10-19：08最终 `0083de42` 已快进合入；同源 `a959...` 的Windows Debug/ReleaseSafe与WSL Linux ReleaseSafe各10/10，完整16GET/7类algo及缺失/异常拒绝覆盖，显式空字符串liability仅按既有合同解释为零。源码归档、producer、日志与产物共58项引用及编译器核验通过，47个提交blob与磁盘字节一致。详见[08证据](08-evidence.md)；旧 `f63cba83` 只属部分checkpoint，不能代表完整guard。05独立接入与最终验证仍未完成，当前唯一Frontier为05，06待05冻结后验收。
- 2026-10-18：仅合入08明确checkpoint `f63cba83`（正常公共合成路径Windows Debug1/1、原始NotImplemented红保留），不触碰08工作树后续未提交修改。该提交提供只读guard接口供05继续实际source编译；逐类拒绝、两平台与显式空liability兼容仍由08补齐，08未resolved，05最后完整接入仍等待08最终验收。
- 2026-10-18：05移除managed EnvFile路径时，必须保留旧pre/postflight完整账户安全门，不能删检查或永久禁用Windows Demo来冒充完成。拆出08原生只读guard，与05不同文件并行；05保持调用点/脚本所有权，新增依赖只阻塞最后guard接入。

- 2026-10-18：07 `864a8521` 已快进合入；[07模块/集成证据](07-evidence.md)及三份正式清单69项带长度SHA引用核验通过，store依赖闭包11项与捕获源码完全相同。AEAD三组10/10，接入后Windows/Linux store各38/38、默认限额拒绝1/1、两OS小entry退出0；全局源码变化仅来自后续04合入，不将旧捕获 `b1df...` 重标为当前 `6805...`。v1辅助排序元数据保留并明确由v2替代。05从86de526d独立实施，须完成前合入本集成tip；当前唯一Frontier为05，06待05完成后冻结。
- 2026-10-18：04 `c0d94d8f` 已快进合入，原实现与中断修改均保留；[04汇总](04-validation.json)及恢复/合并后清单的60项带长度SHA引用核验通过。补证11阶段退出0，Windows auth三模式及Linux ReleaseSafe各10/10、合成transport1/1、C错误矩阵通过；详见[04证据与接口](04-evidence.md)。runtime/demo/private_smoke根入口旧by-value/env接入留05，尚未宣称全入口编译或生产准入通过。05已可实施；07仍在贯通store，06仍等待05与07。
- 2026-10-18：03 `a17d981d` 已快进合入并保留集成已有提交；[03身份清单](03-validation.json)中源码、归档、产物及日志哈希核验通过，Windows/WSL bounded ReleaseSafe各32/32，默认64KiB拒绝1/1，双方native acceptance入口退出0。详见[03证据](03-evidence.md)。AEAD内部状态保护留07接续，不将03完成扩大为此缺口已关闭；04仍在收尾，05等待04，06等待05及07。
- 2026-10-18：03/04已在独立工作树实施。补充只读核查发现标准库 AEAD 的显式子密钥/ChaCha 工作区仍属普通局部，新增07在02接口上窄适配；06必须等待07及store调用点贯通。不将02 KDF证据扩大为AEAD证明。

- 2026-10-18：01 已以 `275620a4` 快进合入集成分支，生命周期持久 writer 锁、stage 防覆盖及旧代次拒绝完成；Windows/WSL Linux Debug、ReleaseSafe 各17/17，原审计 CRD4/v1 合成文件兼容各1/1。详见[01 实施证据](issues/01-close-lifecycle-overwrite.md#evidence)与[源码/产物/日志清单](01-validation.json)。
- 2026-10-18：02 补修 `bbf39841` 已快进合入，保留集成分支已有构建依赖及嵌入fixture身份提交；KDF 显式 scratch 已迁入保护区。Windows ReleaseSafe/ReleaseFast、Linux ReleaseFast 默认限额拒绝与64MiB子进程native成功四组各9/9，详见[02 证据](02-evidence.md)与[v2身份清单](02-v2-validation.json)。首轮8/8及原始日志/清单保留为历史阶段，不能替代补修验收；03/04依赖已完成，当前 Frontier 为03与04，尚未认领。
- 2026-10-18：用户确认直接实施及三组公共seam。复现撤销3→2回退和HMAC残留；KDF的释放后KEK恢复只在ReleaseFast复现，ReleaseSafe原allocator poison覆盖，不能混淆。
- 初始stage改为一次性登记而非隐式覆盖/轮换；新版本轮换不借stage绕过撤销历史。本轮不新建完整轮换控制面或生产发送准入。

## Out of scope

真实凭证、线上请求/交易、部署、Vault/HSM/TPM、新控制面、任意文件系统快照整体回滚的外部反回滚锚、目标机生产资格。
