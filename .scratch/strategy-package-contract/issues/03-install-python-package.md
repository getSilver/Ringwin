# 03：通过 DeployRelease 安装并登记 Python StrategyPackage

Type: task
Status: resolved
Assignee: Codex
Blocked by:
Parent: [模块地图](../map.md)

## Question

如何经现有发布入口安装可信策略包，并让用户看到准确登记结果而不授予交易权限？

## What to build

从签名ReleaseArtifact验证索引、包文件及运行时，原子安装并登记定义；Web展示包身份与拒绝原因。

依据：[策略包与加载合同 v1](01-package-and-loading-contract.md)。仅在所有 blocker 完成后认领；本次发布不代表已认领或取得真实交易/部署授权。

## 完成条件

- [x] 现有DeployRelease贯通签名索引、manifest、全部声明文件和固定运行时的验证、安装及登记，保留既有发布能力。
- [x] 验证规范编码、路径、容量、完整摘要和精确兼容元组；篡改、缺文件或同身份不同内容在导入前拒绝。
- [x] 安装失败不切换current或留下部分登记；相同命令重试幂等，版本前置条件冲突明确返回。
- [x] Web展示真实登记身份、操作结果与失败原因；仅安装时无交易授权。
- [x] 最终包资格证据外置认证并绑定完整包摘要；补充证据不改写已冻结包，不将存在报告等同qualified。

## Answer / 实现证据

2026-10-30：实现完成。控制面代码在独立 worktree
`D:/github/Ringwin-control-plane-strategy-package-03`、分支
`codex/strategy-package-03-control-plane`（基于 `ee66bdae`）实施；本票据及地图在
`D:/github/Ringwin-strategy-package-03`、分支 `codex/strategy-package-03` 维护，保留02成果及当前main文档。
用户已确认公共测试接缝：现有Web DeployRelease → 签名制品验证 → 原子安装/登记 → Web查询结果。
实现提交：`0f558022`（安装、登记与Web）、`d8774609`（跨定义的schema身份内容不可变）。
实现文档为控制面分支的 `docs/strategy-package-release.md`；当前main没有该旧控制面代码，因此本票保留分支边界，不把两个版本的测试数字混用。

### 交付行为

- 复用既有签名ReleaseArtifact和DeployRelease。新增 `strategy_bundle_v1` 未压缩TAR交付；逐头解析并拒绝链接、扩展头、重复/冲突路径、未声明内容、越界容量、非规范JSON及策略内的编译缓存/原生依赖。
- `strategy-index.json`、包manifest、全部声明文件及 `runtime-lock.json` 均校验完整摘要；固定解释器、Host和依赖必须匹配显式批准的兼容元组、订阅及容量策略。Web命令必须携带批准的完整外层manifest摘要，旧单二进制制品仍可发布。
- 暂存文件与完整生成登记表同步后一起发布；已安装目录重试时逐文件复核。失败不留下部分登记；切换/回执结果无法确认则返回unknown并阻止新发布，不能把不确定当成功。登记历史及当前完整登记共同约束定义身份、schema身份/版本的内容不可变。
- 现有Web发布查询和页面显示完整身份、摘要、结果及拒绝原因；拒绝/unknown不会显示成功。外置资格报告复用ReleaseArtifact认证，绑定完整包摘要、精确运行时与具体运行范围；存在报告或安装成功均不授予交易权限。

### 验证与审查

- TDD公共接缝：真实认证HTTP → DeployRelease → 实际POSIX文件安装/登记 → Web查询；仅systemd调用替换为测试回调。测试中解释器/引擎为合成文件，从未执行；安装不导入策略。
- WSL Python全量 `python3 -m unittest discover -s <控制面worktree>/python -p 'test_*.py' -v`：**15/15通过**（12项包发布测试和3项既有认证测试；既有测试仍输出非致命socket ResourceWarning）。覆盖篡改、缺文件、24组非法包向量、身份/schema冲突、完整兼容、回滚保留current、重试、版本冲突、回执故障及外置证据拒绝。
- 控制面分支 `zig test src/main.zig -OReleaseSafe --stack 67108864`：**108/108通过**。该数字属于旧控制面基线，不代表当前main的核心验收。
- 既有 `verify_release_lifecycle.py` 在Windows及WSL通过；`verify_control_plane_release.py`、`verify_owner_session.py` 在Windows通过。Node `tools/verify-strategy-package-ui.cjs` 页面脚本自检、Python编译及 `git diff --check` 通过。
- 双轴并行审查：Standards最终0项；Spec初次发现1项P1（新定义可重定义已发布schema内容），补充红绿回归并在 `d8774609` 修复，复审最终0项。

### 验收边界与继承缺陷

- 既有 `verify_control_plane_wave.py` **未通过**：在普通 `/command` 的重复提交阶段失败。最小复现：首次200，时钟推进2秒后相同请求409 `command identity conflict`；显式相同 `expires_at` 则两次200。源码AST比较确认 `_submit_command` 与基线 `ee66bdae` 完全一致：服务器每次生成默认过期时间后才计算指纹。该继承缺陷未在03扩展修复；不能声称整波验收通过。03的DeployRelease走独立lifecycle路径，其延时/重启重试回归已通过。
- 未执行真实Host/解释器、浏览器自动化、Demo、生产部署或运行资格验收；本票不创建实例或授予交易权限。真实加载与Ready由04负责；系统断电及目标文件系统资格仍需独立证据。
- 测试产生的夹具修改已清理；原控制面worktree既有工作区文件删除及文档修改保留。未合并主线、推送或同步GitHub。

### 02/03工作树合并补充（2026-10-30）

用户要求统一工作树与分支。合并提交 `5e7defb5` 位于
`D:/github/Ringwin-strategy-package-03` / `codex/strategy-package-03`，完整保留
02分支及03控制面实现分支的历史。先前分支说明为各票实施时的历史记录，后续使用此统一入口。

- 保留当前核心源码布局，不恢复旧根级TradingShard；控制面探针复用当前规范genesis、CanonicalEvent.core及权威回放。KillSwitch推进权限事实屏障并撤销Host activation；核心成功空操作由适配层按权威屏障识别为重复投递。
- 当前残余冻结/解冻编号7/8不变，KillSwitch追加为9；Python与Zig信封同步v2，拒绝旧v1，通道两端必须同时使用本版本。旧控制面夹具日志不迁移到当前核心schema。
- 旧Web投影保留主品种及micros字段，结算scale非6或额外组合明确degraded，不跨单位汇总；详细边界见仓库内 `docs/strategy-package-release.md`。
- 原生 `zig build native-contract -Doptimize=ReleaseSafe` 通过；控制通道专项4/4、真实TCP/紧急目录、投影与损坏日志、Web发布、页面脚本，以及Web Pause → EnableTrading → KillSwitch → 回放/操作记录验收通过。
- 合并后Python全量260项：Windows Python3.9.18为247通过、13项按平台跳过；WSL Python3.8.10为259通过、1项环境错误（既有数值测试使用3.8缺失的 `math.ulp`；仓库要求Python3.9+，相关源码与合并前一致）。WSL中的12项包发布和3项认证测试均通过，既有非致命socket ResourceWarning仍在。
- 当前核心 `zig build test -Doptimize=ReleaseSafe --summary all` 编译成功并进入全量运行；额外运行近半小时后主动停止，**未获得全量通过结论**，不沿用02或旧控制面分支的测试计数。合并适配以已通过的原生合同、签名通道、真实Web操作及回放专项为证据。首次扩展通道运行发现的重复投递计数问题修复后，最终专项4/4通过；被替代的旧扩展运行已停止。
- 双轴合并审查及重复投递适配复审：Standards 0项、Spec 0项。未实现04、未执行Demo、生产部署或浏览器自动化；旧普通命令默认expiry幂等缺陷继续单列，不声称旧整波通过。

