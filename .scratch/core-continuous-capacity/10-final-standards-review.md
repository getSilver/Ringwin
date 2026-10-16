# Frontier 10 冻结候选 Standards 复核

基线：`4ea4c3ee3f6bfc4a822196649fb011e3b5f0dfa2`。按AGENTS、CONTEXT、ADR0004/0010/0011/0013–0016、Zig规范和十二项smell baseline，独立复核非本人编写的observation、混合生命周期、共享账户、main接入、Store修复及runner/auditor。未以本人fault模块自审替代先前独立边界审查。

**未发现确认P1/P2或需阻断的硬规则违例。**

- `core_observation_capacity_acceptance.zig:261,393` 抽取既有公共初始化/选单链，activation后使用真实reference_price；`windows_observation_file_acceptance.zig:125` 实查500唯一映射、方向、独立路由风险及持久发送归属。该夹具全局100live、4terminal，未扩大容量常量。
- `windows_capacity_acceptance.zig:521,561` 的schema2保留三类混合生命周期及四portfolio独立stream；`windows_capacity_shared.zig:50` 经CoordinatorOwner持久更新真实摘要，保持recovery_only与既有leases。生命周期夹具全局常驻live9、逐单advance时live峰值10、terminal峰值4，未将恢复副本计作新订单或权限。
- `durable_store.zig:1643` 仅objects与roots均明确FileNotFound时返回OrderHistoryUnavailable且保留gate；roots存在、其他I/O及认证失败仍关闭。权威状态已有history_root时，Owner/Coordinator继续拒绝Unavailable，未把缺失解释为首次。
- runner保留deadline、既有证据拒写、构建/消费artifact前后绑定、producer冻结及精确barrier/digest marker。Python3.9的zip改为先校验双方长度，没有恢复截断比较漏洞。auditor核对完整套件终态、日志/文件hash、实际旧新恢复及未扩大app栈，未提升目录耐久性或生产资格。

判断性建议：`windows_capacity_acceptance.zig:496` 与 `windows_observation_file_acceptance.zig:183` 的ledger_digest来自ledger_summary，可日后澄清命名；完整canonical/economic摘要仍参与恢复比较，不构成P2。十二项smell未形成其他需报告问题。

只读实核：114文件manifest逐项相同，源码SHA256为`73532d4ae117f849e083011cde02b169d8862b457c1e8f362e40571b31492bce`。以下producer逐项匹配`10-final-v1-identity.json`：

| producer | SHA256 |
| --- | --- |
| run-07-command.py | `9a248c655a81666d0208a787868d5dd0ec28fbb8aac764643bd6898110352d14` |
| run-10-command.py | `67232ef1c8639207199a6f6dae76b1463131934d2162e2ddc8d8792b861fe9b8` |
| run-10-final-acceptance.py | `2f75711cf091a4f3a60be9f121eba217d913575b0ec50697dfc4ea87bc5a303d` |
| run-10-file-processes.py | `7b3d9424e919588eac6211d783ee61abb3a3e56b77d49515dfc181721c612255` |
| audit-10-final.py | `6e33f67b1470aff5bc698a04392095c8a0aef5653a103fc8d3e8c7eca85f4a95` |
| collect-10-host.ps1 | `7c85079d24bd1123cfa88c31871fdcb1a3567d2e49fd1bc6b9c2819f757eab7f` |

已读取preflight-v2的12进程结果：普通退出成功、两次指定中断非零退出、recover文件清单不变；Store最小回归、mixed-v6及observation-v4定向日志分别1/1、1/1、2/2通过。最终流水线仍在full-releasesafe-build，**尚未完成验收**。本轮仅写review文档，不改producer/src、不跑全套。
