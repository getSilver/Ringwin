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
2. [建立受保护缓冲与可清零密码学工作区](issues/02-protect-secret-and-crypto-workspaces.md) — in-progress；blocked by 无
3. [贯通凭证存储的保护内存与安全输入](issues/03-integrate-protected-store-and-input.md) — blocked by 01,02
4. [清理认证与传输副本](issues/04-protect-auth-and-transport-copies.md) — blocked by 02
5. [贯通网关受控凭证注入](issues/05-bind-gateway-credential-ownership.md) — blocked by 03,04
6. [最终冻结、回归与独立审查](issues/06-seal-offline-security-evidence.md) — blocked by 05

## Frontier

- [02 保护内存与密码学工作区](issues/02-protect-secret-and-crypto-workspaces.md)

## Decisions so far

- 2026-10-18：01 已以 `275620a4` 快进合入集成分支，生命周期持久 writer 锁、stage 防覆盖及旧代次拒绝完成；Windows/WSL Linux Debug、ReleaseSafe 各17/17，原审计 CRD4/v1 合成文件兼容各1/1。详见[01 实施证据](issues/01-close-lifecycle-overwrite.md#evidence)与[源码/产物/日志清单](01-validation.json)。
- 02 仍在实现，补齐 KDF 显式栈 scratch 保护窗口；旧阶段提交不作为完成依据，当前唯一 Frontier 为02，03/04暂不启动。
- 2026-10-18：用户确认直接实施及三组公共seam。复现撤销3→2回退和HMAC残留；KDF的释放后KEK恢复只在ReleaseFast复现，ReleaseSafe原allocator poison覆盖，不能混淆。
- 初始stage改为一次性登记而非隐式覆盖/轮换；新版本轮换不借stage绕过撤销历史。本轮不新建完整轮换控制面或生产发送准入。

## Out of scope

真实凭证、线上请求/交易、部署、Vault/HSM/TPM、新控制面、任意文件系统快照整体回滚的外部反回滚锚、目标机生产资格。
