# 12: 封存容量闭合证据并交接生产资格

Type: task
Status: resolved
Assignee: Codex
Blocked by: [10 验证 Windows 文件持久化与持续恢复](10-verify-windows-file-recovery.md), [11 验证 Linux 文件持久化与持续恢复](11-verify-linux-file-recovery.md)
Parent: [核心持续运行容量闭合](../map.md)

## Question

如何封存共同业务合同与两平台各自的小规模功能恢复证据，明确未测容量／压力范围和后续生产工作，不把本轮通过等同于生产就绪？

## What to build

封存共同业务合同与两平台各自的小规模功能恢复证据，逐项标注已闭合功能、失败、未测容量／压力目标及后续生产工作，不把本轮通过等同于生产就绪。

## Acceptance criteria

- [x] 核对 01–11 的证据与最终源码身份；平台构建 artifact 可不同，但必须绑定同一业务源码基线及各自构建参数，变更后的受影响检查重跑。
- [x] 汇总全部功能点覆盖，至少10轮检查点／归档轮转；每个夹具跨全部分片live和terminal总量分别不超过100，包含部分组合做市、混合套利意图、热点、故障、恢复及零重发，不能只测空事件循环。原100,000完整生命周期与千单压力门槛明确deferred／未测，仅保留为设计参考，不执行该负载。
- [x] 证据含可复现命令、种子、源码／配置哈希、schema、原始结果、失败及未执行项；逐项映射01–11功能义务与实际证据。内存／RSS、队列、日志增长、延迟及恢复耗时仅报告小功能样本观察，容量、资源预算、索引成本与目标平台性能资格未测，不以本轮通过宣称达标。
- [x] 分别列出Windows/Linux文件功能证据、未测容量／压力／资源／性能资格，以及未完成生产合同、进程、安全、真实隔离、线上Venue、soak／影子／Canary工作；不互相提升资格。
- [x] 本票依赖两个平台仅为整波封存；票 10/11 各自通过后即可推进对应平台生产专项，不把另一平台或本票当作单平台资格的额外门槛。
- [x] 确认无未完成本轮功能验收项且完整列出失败、未测与deferred范围后，才可封存本轮功能结论；地图closed仅表示该明确功能范围完成，不表示原容量／性能设计目标或生产资格完成。不部署、不授权真实交易。

## Evidence

2026-10-18：完成共同115源码244f3ae7封存；票12未改Zig源码。Windows同源重建的16阶段、333项受影响Debug测试、应用/CLI各十轮30新进程及两组各五实际数据目录审计全部通过；Linux精确复用票11同源完整ReleaseSafe/Debug各623通过、1指定memfd IPC skip、0失败及60新进程证据。历史Windows完整624/624保留原源码身份，不改称当前全量。

[覆盖矩阵](../12-coverage.md)逐项映射01–11义务；[独立平台交接](../12-production-handoff.md)列出未测容量/生产专项及缺失旧票规格；[完整证据](../12-evidence.md)含复现、资源、失败/中断与范围。独立Standards/Spec均无剩余P1/P2。

[整波证据包](../12-final-v2-wave-evidence/summary.md)含identity/workload/samples/faults/summary、audit、physical-audits及manifest，3334个原始/历史引用；[封存复核](../12-final-v2-seal-verification.json)验证7个manifest文件、3334个引用与v1中断98项子引用全部SHA一致。当前恢复完整authority、accepted/Unknown零重发；每夹具live及terminal跨分片各≤100。旧失败/中断、未执行项原样保留。

本票resolved和父地图closed仅指上述小规模功能范围完成。千单/100000生命周期、压力、资源预算、物理索引成本、目标性能/断电/安全/NodeFence、线上Venue、soak/影子/Canary及生产资格未取得；两平台可独立推进后续专项，不互为额外门槛。未部署或执行真实交易。

## Out of scope

本次封存不包含部署、真实 Demo/Testnet/生产下单，也不自动授予平台或 Venue 生产资格。
