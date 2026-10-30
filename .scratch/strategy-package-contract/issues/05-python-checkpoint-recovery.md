# 05：Python 实例 checkpoint 与重启恢复

Type: task
Status: resolved
Assignee: Codex
Blocked by: [04 创建 Python StrategyInstance 并无权运行至 Ready](04-python-instance-ready.md)
Parent: [模块地图](../map.md)

## Question

如何从真实checkpoint与非空尾日志恢复同一实例，保持决定和序号连续？

## What to build

实际保存、发布、读取checkpoint，通过非空尾日志无权恢复至指定屏障，并展示恢复进度和失败结果。

依据：[策略包与加载合同 v1](01-package-and-loading-contract.md)。仅在所有 blocker 完成后认领；本次发布不代表已认领或取得真实交易/部署授权。

## 完成条件

- [x] snapshot的私有payload经身份、schema、cursor、内容摘要及序号检查后发布和持久保存，重启从已验证记录读取。
- [x] 同一实例重启保留定义、配置和意图历史，HostSession按既有规则更新；非空尾日志可追赶至指定屏障。
- [x] 同一事件流不同分批以及checkpoint加相同尾日志得到一致决定、私有摘要和next IntentSequence。
- [x] 无权重放按相同路径消耗意图序号且零外部效果；缺checkpoint、日志缺口或不兼容schema拒绝空状态重启。
- [x] 恢复异常后的可疑状态不发布有效checkpoint；Web可区分恢复中、Ready及拒绝原因。

## Answer / 实现证据

2026-10-30：04 已在 Windows 路径完成独立无权 Ready、硬内存预算与 Host 生命周期验收，本票进入 Frontier，可基于 Windows 接手；未认领、未实施。依据 ADR0010，Windows 不以 Linux 通过为前提，Linux Host 资源验收缺口继续单列，不由 Windows 证据替代。

### 2026-10-31 Windows 实施与验收

- 在指定工作树、分支 `codex/strategy-package-03` 实施，起点 `c6489e2a`。上述未认领说明仅记录历史状态。
- 真实私有 payload 经 snapshot/restore/validate 往返及 IntentSequence 检查后，由 Zig ManagedHost 请求 checkpoint；现有 QSSC/QSSD codec 校验实例、定义、配置版本、state schema、cursor、next sequence、CRC 和摘要，Repository 使用 DurableStore 先持久内容再提交发布引用，提交完成后才返回 Ready。
- 重启保留原绑定和意图历史，启动前持久保留共享候选 Host 命名空间的单调 generation。原生仓库按已提交记录恢复，支持完整历史或非空尾日志；首次及后续发布成功、Web 尚未确认的窗口也可通过 latest 解决，包括仅剩合法尾日志的情况。缺失或不兼容时不初始化空状态。
- Web 复用认证、CSRF 和实例入口：POST `/api/strategy-instances` 仅传 operation=recover 和 strategy_identity；GET 展示 Recovering 的 cursor/barrier、Ready 的 checkpoint 证据和 Stopped 的拒绝原因。恢复输出按正常回调消耗序号后丢弃，不授予交易权限，不产生核心命令或外部订单。
- 验收比较不同分批、checkpoint 加尾日志的完整 OrderIntent trace、QSSD、checkpoint 内容身份及 next sequence；覆盖缺内容、损坏、日志缺口、不兼容 schema、序号不符、恢复异常、未确认发布重试、跨实例 generation、70 KiB 私有状态及并发进度查询。异常状态不发布新 checkpoint，原已验证记录保留。

### 验证证据

- [最终 Python 全量](../evidence/05-python-windows-final.log)：299 项，285 通过、14 平台 skip，退出码 0；保留一条未关闭 socket 的 ResourceWarning。此前 [294 项中间运行](../evidence/05-python-windows.log) 早于最终复审修正，不作为最终代码验收。
- [Zig 全量二进制执行](../evidence/05-zig-cached-tests.log)：821/821，退出码 0，2026-10-31 00:57 完成；缓存二进制的源归属和首次整波命令失败边界见 [验证说明](../evidence/05-validation.md)。
- [checkpoint 专项](../evidence/05-zig-checkpoint.log)：ReleaseSafe、仓库大栈配置，84/84，退出码 0；[最终 ReleaseSafe 构建](../evidence/05-zig-build.log)：9/9，包含当前候选适配器。
- Python py_compile、页面脚本 node --check、zig fmt --check、git diff --check 通过。code-review 修正复审：Standards 0 项剩余发现，Spec 0 项剩余发现；已修正 generation 复用、Linux 文件大小上限和未确认发布的仅尾日志恢复，并补齐完整决定内容比较。

### 资格边界

按 ADR0010 在 Windows 离线功能范围完成，开放 06，但不认领 06。测试使用真实签名适配器、解释器和 Host，以及合成 engine payload/canonical 输入；不等于 live node、经济、磁盘断电、生产、Demo 或部署验收。Windows 使用既有 verification file adapter；Linux Host 资源和运行证据继续单列，须在真正实施 RLIMIT_AS 的内核补齐。本轮没有访问凭证或执行真实交易。

