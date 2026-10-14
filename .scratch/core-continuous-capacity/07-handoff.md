# 07交接：资金费、账本与对账历史归档

06已关闭并提交，代码基线为`a8b8804623ff9fa4f24189a2216f7c8c347321e0`。当前业务源码身份为`c508f89c8c6faae0c428e3e2195df957d4377a453a673ee772edec2c9d2b17b4`（91份源码）。本文件只交接07的当前源码调查及实现约束；07尚未实施，本代理按用户要求不继续07。

## 工作位置及已验证基线

- 唯一实施工作树：`D:\github\Ringwin-core-continuous-capacity`；分支：`codex/core-continuous-capacity`。不要修改原`D:\github\Ringwin`。
- 编译器：`D:\Program Files\zig\zig.exe`，版本`0.17.0-dev.315+5b647b792`；生产合同journal37/state41/registry35，Gateway快照6。
- 最新完整ReleaseSafe和Debug串行各551/551退出0；应用64MiB、CLI256MiB重建及`--offline-fixture`、`--windows-chain-test`各退出0，源码无漂移。见[06证据](06-evidence.md)、[审查](06-review.md)、[源码清单](06-final-v2-source-manifest.json)、[产物身份](06-final-v2-artifacts.json)、[46项核对](06-final-v2-acceptance-audit.json)。`python .scratch/core-continuous-capacity/audit-06-final-v2.py`核对这份既有基线；07改源码后应创建新清单与新前缀，不覆盖06。
- issue05/06已resolved；07/08为Frontier，09–12仍有blocker。下一代理只接[issue07](issues/07-close-funding-ledger-and-reconciliation-history.md)，不要混入08或后续票。没有运行中的测试/编译器。
- exe/pdb/汇编及大量历史日志仍留在本地，未提交二进制；旧失败有明确原始结果，不能使用旧身份或仅编译成绩关闭07。不清理未跟踪文件，不批量stage。

06已提供可复用的完整Fill资格与typed历史、独立累计承接、热/冷查证、快照交叉校验、连续业务根、公共故障恢复和零重发。恢复复用owned candidate并保留fence/失败回滚；Gateway快照scratch由Windows Owner显式持有，File发布96B header加原payload到同tmpfile后sync。不要退回大栈嵌套、隐藏分配或修改64MiB应用栈绕过问题。

## 当前缺口

- `economics.zig:917`的资金费只有seen指纹及相关ledger，没有归档所需的完整原始输入、已应用金额/归属及全部账本承接记录。零金额可能不产生账本，但幂等身份仍不可丢失。
- `trading_shard.zig:2077`的canonical funding没有结算时点投资组合归属证明，正确进入Suspense并锁存。Core已有明确声明ownership的路径；归档必须保存其已有结果，不能把canonical的缺证明改成true，也不能用接收时持仓猜历史分配。
- `trading_shard.zig:2383`把所有对账绑定初始economic baseline，事实引用最多16项。即使成交已冷归档，累计`archived_fill_count`仍参与完整覆盖；删除seen或降低计数不能允许不完整对账。
- `trading_shard.zig:2420`只有Fill冷覆盖，funding依赖热seen的canonical digest。Core资金费和冷资金费需要认证实际已应用经济摘要，并分别保存原canonical/Core语义，不能混用两种摘要。
- `demo_authority.zig:695`、Gateway及Core最新业务根目前区分order/fill。新增经济种类必须保留相邻世代与旧根链，经济根推进不释放accepted/Unknown或授权发送。

## 下一张票的纵向切片

1. 通过原有公共Core/CanonicalEvent、Owner、Gateway、Store seam保存完整已应用资金费记录。保留原时钟、账户/产品/资产/规则、原归属声明和完整相关ledger；清晰区分原source摘要与经济结果摘要。资格验证原屏障、当前经济状态、所有引用和账本守恒；未解决Suspense/break、未覆盖或缺可信时间的记录保持pin。
2. 保存已完整核对的对账窗口，窗口承接cursor独立于初始economic baseline。完整记录前窗口/root、from/through、逐资产before/after余额、原始查询/来源证据及确切经济事实集合；下一窗口before必须逐资产等于前窗口after。
3. 对账窗口先核对全部热/冷事实与区间，再Store发布、Core持久提交cursor、后释放相应旧窗口明细。不得以回收改变当前经济余额/持仓/保证金/成本/Funding/PnL；初始baseline不重写。未覆盖事实不能通过清空热表消失。
4. 旧身份先认证冷历史，same无经济副作用，conflict锁存。已闭合through之前的迟到新经济身份失败关闭，不能在闭窗后重新归入新窗口；不以可回拨接收时钟推进承接边界。
5. 复用完整历史批次、Core提交和Gateway经济根协议，新增typed身份及完整资格，并同步快照、摘要、恢复交叉校验和必要格式版本。强制执行的尚未完成分配/ack继续pin，其完整回收由08负责。

资金费正例可沿用既有明确归属的Core seam；canonical缺历史归属证明仍保持pin。这证明已有经济结果持续恢复，不证明Venue历史FundingAllocation能力，不新增自动分配或网络权限。

## 小规模公共验证

- 一单真实成交后归档成交/终态订单，留下零订单但有持仓；十个资金费及对账窗口，保留完整第三资产费用和余额、成本、保证金、PnL、ledger及摘要断言。
- 实际零持仓且无经济新事实的窗口需要明确完整性和连续承接；零金额结算仍保留身份，不以无ledger当作未发生。
- 热/冷same与conflict、漏引用/漏余额、窗口before篡改、迟到旧区间新身份、缺可信时钟、canonical归属未知及未解决break必须分别验证失败关闭/pin。
- 历史发布、Core提交、Gateway承接、检查点及恢复逐边界注入故障；恢复旧或新完整经济状态和窗口cursor，计数不回退，SDK调用不新增。
- 每类live/terminal全夹具合计不超过100；保留检查点频率和最终恢复。不执行千单、容量压力或资源资格测试。

独立Spec只读评估认可上述最小方向；特别提醒覆盖计数缩小和时间回拨遗漏事实是P1风险。本文件没有07实现/运行证据，具体合同及ADR应与07实现一起冻结、审查和验证。

## 实施及验收纪律

先读根CONTEXT、ADR0013/0014、issue07和地图；复用既有VenueAdapter→CanonicalEvent→TradingShard/Owner→Store/Gateway seam，不把私有协议翻译搬到runner，不新建控制面CLI。不请求已授权范围的重复许可；用户允许子代理，指定6.1 Sol中。

以公共业务回归先红后绿，源/状态/原始结果均可复现。Debug/ReleaseSafe完整测试使用`zig test src/main.zig -O <模式> --stack 268435456`并串行运行；应用用既有`zig build -Doptimize=ReleaseSafe`保持64MiB，CLI可按既有256MiB构建。命令输出用原生文件句柄捕获，保存退出码和源码/产物/日志哈希。两个完整模式实际终态、重建应用/CLI两模式、Standards/Spec独立审查均完成后才关闭07并提交。慢不是停止理由；不因观察等待到期重启已有活进程。

每个夹具跨全部分片live和terminal总量分别不超过100，允许500观察组合；不跑千单或容量压力，不降低检查点频率或省略恢复断言，生产限制不改。RSS/索引成本、原1024/100000生命周期与目标平台性能仍deferred；Windows输出的production_qualification=false/read_only=not_run/demo_live=not_run不提升。无部署、Demo/Testnet/生产真实订单或远程故障操作授权。

06如实保留的未测边界：Owner坏proof/record关闭只做源码回查，第三资产历史记录未逐条读取native ledger posting。07账本/混合费用公共验收宜补充实际完整记录读取，但不把旧源码审查变成运行证据。
