# 02：原生 StrategyDefinition 静态注册与构建验收

Type: task
Status: resolved
Assignee: Codex
Blocked by:
Parent: [模块地图](../map.md)

## Question

如何让一个最小原生策略通过静态注册、构建清单和定义身份校验，形成可重复验收的交付合同？

## What to build

细化原生合同，以一个最小原生策略贯通静态注册、构建清单和定义身份校验；明确与Python共用及不同的合同边界。

依据：[策略包与加载合同 v1](01-package-and-loading-contract.md)。仅在所有 blocker 完成后认领；本次发布不代表已认领或取得真实交易/部署授权。

## 完成条件

- [x] 交付原生合同，明确定义身份、入口注册、参数/状态合同、兼容范围及构建清单绑定；复用已有领域术语。
- [x] 一个最小原生策略随ReleaseArtifact静态构建并可按清单定位，定义身份与实际注册一致。
- [x] 缺失注册、重复身份或清单不一致时构建验收失败，提供正反向构建证据。
- [x] 不引入动态库加载或生产节点编译；运行发布与激活由09票接通。

## Answer / 实现证据

2026-10-30：在独立 worktree `D:/github/Ringwin-strategy-package-02`、分支
`codex/strategy-package-02` 实施，基于 `1b77d655`，实现提交 `8ba7d5ed`。
构建验收、Debug与ReleaseFast全量回归均已通过，本票完成；地图仍保持open。
以下为实现及离线验收证据。

- [原生构建合同 v1](../../../docs/native-strategy-contract.md) 定义不可变身份、静态入口、
  参数/状态schema、精确兼容元组及ReleaseArtifact绑定，说明Python共用/不同边界。
- [静态注册表](../../../src/strategy/native_registry.zig) 由
  `TradingShard.native_definitions` 暴露；按身份取得具体实现类型，不动态加载。
  独立[期望清单](../../../src/strategy/native_manifest.zig)与实际注册、算法/schema字节摘要逐项核对，
  编译期与构建入口均失败关闭。
- 最小[native_observer](../../../src/strategy/native_observer.zig)定义身份为
  `a21994db11534bf5b193c5aa89000001`；只观察ReferencePrice并更新私有状态，不输出OrderIntent。
  create/validate/onReferencePrice使用静态Config/State与精确错误集；不增加核心持久状态字段。
- `zig build` 生成 `bin/ringwin.exe`、`share/ringwin/native-strategies.json`及两份schema合同。
  清单绑定 Zig `0.17.0-dev.315+5b647b792`、目标与优化模式、native API 1、canonical 18、
  registry 48、journal 50、core state 54，schema版本均为1。
  `--native-strategy-build-test`实际从TradingShard静态注册表定位并调用最小入口。

### 已完成的验证

- `python tools/test-native-strategy-build.py -v`：8/8测试通过，包含2个正向及10个拒绝向量。
  正向覆盖独立验收入口及实际安装后二进制/清单/schema字节核对；拒绝覆盖缺失注册、
  注册表/清单重复身份、入口/定义身份/兼容版本不一致、算法/config/state字节变化与零身份。
  所有拒绝向量在临时源码副本执行 `zig build`，断言具体拒绝原因，不改工作区制造失败。
- TDD首个正向用例先因缺失 `native-contract` 构建入口失败；增加入口后通过。
  重复注册用例先揭示错误被归为MissingRegistration，调整检查次序后明确为DuplicateDefinition。
- `zig fmt --check`（全部变更Zig文件）、`git diff --check`通过。
- code-review基于 `1b77d655...8ba7d5ed`：Standards 0项、Spec 0项发现；
  测试栈修正 `8ba7d5ed...4de76486` 的两项复审也均为0项发现。
- 默认测试栈问题已定位：初次Debug全量304/820通过、516项栈溢出；
  ReleaseFast全量343/820通过、477项以253退出。独立基线worktree `1b77d655`
  的 `state digest binds instrument trading margin and economic position authority`
  在64 MiB测试栈下同样明确报Stack overflow；基线与当前代码在512 MiB下均3/3定向测试通过。
  `build.zig`因此只将测试可执行文件的栈设为512 MiB（提交 `4de76486`）。
  修正后 `zig build test --summary all`（Debug）及
  `zig build -Doptimize=ReleaseFast test --summary all` 均全量820/820通过。
  未修改交易核心或生产二进制栈，也未将此结果宣称为旧core-wave脚本整体通过。
- 本次Debug构建的SHA-256：
  - `ringwin.exe`：`02883baa8992ea03ef864c9ee262ce6406077e600167fa5c87f573a69845bfb4`
  - `native-strategies.json`：`454b825311f5188e2a8d111439b7e83e161ba4129a9c60d802b293be3d7013db`

这些哈希只记录本次离线构建，不是签名ReleaseArtifact或资格报告；最终发布时二进制、清单及
合同文件仍须由同一签名payload覆盖，最终制品证据外置绑定。现有单payload发布器的多文件安装、
共同索引、Web实例绑定、Ready/EnableTrading与版本替换由09票接通。
未执行真实交易、Demo、部署或Linux运行资格验收，地图仍保持open。

