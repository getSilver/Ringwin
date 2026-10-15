# 09 Standards review

固定基线：`0779b48ec7a6f91e989f6d3c68049d0b012ff3dc`。审阅命令为 `git diff 0779b48ec7a6f91e989f6d3c68049d0b012ff3dc -- src`，另完整读取三个未跟踪的 `continuous_capacity_acceptance.zig`、`continuous_backpressure_acceptance.zig`、`continuous_account_acceptance.zig`。基线至HEAD无新增提交，review对象为当前工作树。

标准来源：根AGENTS.md、CONTEXT.md、`docs/agents/domain.md`、`docs/agents/issue-tracker.md`、ADR0004及0011–0016、Zig skill。已使用`rg --files --hidden`显式搜索：不存在CODING_STANDARDS或CONTRIBUTING文件，也无额外嵌套AGENTS。按全部十二项smell baseline审阅；仓库既有模块和公共seam优先，未将工具强制的格式项重复列为发现。

**无剩余确认P1/P2。**

计数扩大保留在各自所有者：Coordinator DTO采用u16并同步独立snapshot9、digest域及publish_summary type14，旧type1拒绝；VenueEvidence为内存证据，未误升Core schema。边界谓词实际接入生产追加或槽位分配，未伪造大数组状态；Store在原身份扫描统计used。Core继续不做历史I/O，归档与恢复沿用Owner/Store/Gateway责任边界。bootstrapInto替换按值bootstrap符合现有in-place所有权。

新增夹具范围已按业务路径核对，而非将顺序历史累计误判为并发：四片十轮夹具正常驻留live4，逐单处理中峰值live5；单片热点最多3个terminal且在进入下一片前归档，全局terminal峰值3。mixed夹具live最多5、terminal3；四个backpressure夹具各至多1个订单身份同时驻留，前置已归档订单不累计为并发；共享账户夹具四片live4，前置经济订单逐片归档、terminal最多1。恢复对象是同一历史的校验副本，不生成额外业务身份。全部均满足全分片live≤100、terminal≤100。

此结论仅覆盖上述开发中源码的Standards轴，不替代Spec、最终冻结源码测试、资源实测或平台资格。观察组合全局唯一身份数量的疑问已交Spec轴核对，未将其混入Standards结论。本轮仅写此review文档，不改源码、不提交。

## 最终冻结增量复核（2026-10-16）

固定基线仍为0779b48e；独立检查前次Standards报告后的增量，重新读取当前src diff及三个continuous文件全文，并复核AGENTS、CONTEXT、领域/本地tracker规则、ADR0004/0011–0016与Zig规范。十二项smell baseline逐项作为判断性启发核对，未把工具格式项、既有公共seam导航或测试夹具的有限重复升为硬性违例。**未发现确认P1/P2，也无需要阻断本候选的Standards问题。**

- observation新增的spot0 long/perpetual75 short以规则分子/分母交叉相乘核对相同base量；perpetual76跨route0 long/route1 short分别保留Venue、账户、品种及完整风险资格。partialFill随命令side处理经济方向，恢复断言同步更新。仍每route25live、全局100live，取消后重建不产生额外第101个live；四route各保留一个terminal，全局terminal最多4。不把两个独立发送描述为Venue原子事务，符合ADR0012的品种/资产单位与路由责任。
- OMS total_count由==改>=仅收紧拒绝边界；1025/5121通过纯数字谓词覆盖，没有填满生产订单数组或伪造发送证明。
- continuous首单从持久command_history[0]取得，适用于本夹具此前无订单的初始化路径；每片真实2lot Fill与report保留完整经济状态，十轮冷重复不重记。导出原始DispatchEvidence后，经Store在当前已提交root上真实查证，再调用Gateway.retryArchivedDispatch；归档及恢复前后均核对发送计数，不以手工构造结果替代历史证明，符合ADR0013/0014。
- mixed新增两腿close及独立hedge均经正常准入和Gateway；两个部分成交entry仍live，三个完全成交close/hedge为terminal，其后两个quote及一个Unknown使live峰值5、terminal峰值3。四片十轮仍真实并发峰值live5、terminal3；恢复校验副本没有新的业务身份或网络发送。
- backlog、storage、结构尺寸与submit_total_ns均为小夹具观测：submit累计含维护工作，不能解释为InternalOrderLatency；archive_quota不是实测RSS、保留预算或目标平台资格。新增日志仅读取计数，没有清空历史、关闭校验或扩大生产容量。
- 四片Golden只替换Coordinator v9/u16摘要身份。源码中经济断言、journal replay、snapshot+tail及中断恢复的三路径等价断言均先于Golden比较；09-four-shard-digest-preflight.log确在最终FourShardEvidenceDrift失败，actual与随后green固定值一致，未发现通过跳过前置验证刷新Golden的行为。

只读调用run-09-command.py的source_manifest()取得当前110文件清单；其files逐项与09-final-v1-source-manifest.json完全相同，整体source_tree_sha256为`7d70c32ad257806e99695fa9692822373977ca2c9410695be1541afd9627fc02`。此身份覆盖src/**/*.zig与build.zig（当前无build.zig.zon）；本review Markdown不在源码身份内。由根代理执行该冻结身份的最终验证；本增量复核未运行完整套件、未修改源码。
