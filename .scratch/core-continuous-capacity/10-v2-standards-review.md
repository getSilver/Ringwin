# Frontier10 v2 Standards 独立终审

基线 `4ea4c3ee3f6bfc4a822196649fb011e3b5f0dfa2`。依据 AGENTS、CONTEXT、ADR0004/0010/0011/0013–0016、Zig规范及完整十二项smell baseline，复核非本人编写的观察/混合生命周期/共享账户模块、公共helper、main、Store修复和六个producer；本人fault模块不替代独立边界审查。只读源码/脚本，未运行全套。

**未发现确认P1/P2或阻断性硬规则违例。**

硬规则核对：`src/demo_authority.zig:576` 的candidate至applyAdapterBatch前事务尾部、`src/trading_shard.zig:1580` 的candidate至adjustMarginBuffersForReservationChange前事务尾部，分别与基线逐字相同。仅将大candidate留给实际提交/替换路径；policy、冷证明staging、admission标志、durable commit及失败处理未变。`trading_shard.zig:853,865,3496` rollback指针和history finalize路径未改；没有把proof前状态误用作proof后回滚点。

`durable_store.zig:1643` 只把objects、roots同时明确不存在解释为尚无history；已发布root缺objects及其他I/O仍关闭。恢复权威已有history_root时仍拒绝Unavailable。新增观察夹具全局100live/4terminal；混合夹具live峰值10/terminal峰值4；共享账户仍经Owner持久更新摘要并保留recovery_only/旧leases。

`run-10-final-acceptance.py:104` 先执行两个产物十轮，再跑两mode全套；phase/resume入口已删除，既有prefix拒写。`audit-10-final.py:88` 将最终artifact SHA绑定对应build结果；runner启动前、消费后及封存前重核artifact，并重核source/producer。精确marker、自有子进程kill、timeout/失败留存规则保持。

判断性结论：十二项smell未产生新增需报告项。两个private noinline helper保留单一事务责任，未扩大公共接口；这不证明所有替换路径的栈峰值。实际thread stack peak仍未测。

当前manifest只读实算：114文件，SHA256 `c29cba9ae0f97a53820b71401040ae1e0c8e0662c990e0c1a94683170c247885`。

| producer | SHA256 |
| --- | --- |
| run-07-command.py | `9a248c655a81666d0208a787868d5dd0ec28fbb8aac764643bd6898110352d14` |
| run-10-command.py | `67232ef1c8639207199a6f6dae76b1463131934d2162e2ddc8d8792b861fe9b8` |
| run-10-final-acceptance.py | `d8fdc7b6b0aab683e5d3a1a09651705ae8cf4baf69e4c0aa3347f23f11c317e1` |
| run-10-file-processes.py | `7b3d9424e919588eac6211d783ee61abb3a3e56b77d49515dfc181721c612255` |
| audit-10-final.py | `218b63279c6e5ac57a0befb80f7ea8337503e54382d468e2034eaf40b9863272` |
| collect-10-host.ps1 | `7c85079d24bd1123cfa88c31871fdcb1a3567d2e49fd1bc6b9c2819f757eab7f` |

**v2实际64MiB十轮、完整两mode及最终audit仍pending。** v1两mode各623通过不能替代v2验收；v1应用StackOverflow及其他失败证据必须保留。此报告仅为Standards源码审查，不提升容量、断电耐久性或生产资格。
