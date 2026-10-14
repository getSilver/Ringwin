# 06 成交与费用历史归档证据

Status: resolved

本票基线为05提交fd1513e8d87bc51ac30e12b179fc2f15e10e03db。使用独立工作树和codex/core-continuous-capacity分支，原工作树未参与修改。订单夹具遵守每类live/terminal总量不超过100，不执行千单或容量压力；生产容量常量未改。

2026-10-14最终功能验收完成。冻结源码`c508f89c8c6faae0c428e3e2195df957d4377a453a673ee772edec2c9d2b17b4`、91份源码，完整ReleaseSafe/Debug串行各551/551退出0；应用64MiB、CLI256MiB按同源码重建及两项离线模式均退出0。12条构建/执行命令的日志及退出记录、源码无漂移、四个产物哈希和PE栈、五轨迹及离线链输出已通过[46项验收核对](06-final-v2-acceptance-audit.json)，复现核对入口[audit-06-final-v2.py](audit-06-final-v2.py)。用户要求06关闭后停止，本代理不实施07。

| 最终范围 | 实际结果 | 记录 |
| --- | --- | --- |
| 完整ReleaseSafe | 551/551退出0，09:19:25Z–09:36:45Z | [日志](06-final-v2-full-releasesafe.log)、[结果](06-final-v2-full-releasesafe.result.json) |
| 完整Debug | 551/551退出0，09:37:40Z–10:14:01Z；与ReleaseSafe串行 | [日志](06-final-v2-full-debug.log)、[结果](06-final-v2-full-debug.result.json) |
| 应用与CLI重建 | 两者退出0；应用栈64MiB未增加 | [应用](06-final-v2-app-build.result.json)、[CLI](06-final-v2-cli-build.result.json)、[产物身份](06-final-v2-artifacts.json) |
| 应用两项离线模式 | 各退出0，五轨迹恢复及离线进程链完成 | [offline](06-final-v2-app-offline-fixture.result.json)、[Windows链](06-final-v2-app-windows-chain-test.result.json) |
| CLI两项离线模式 | 各退出0，五轨迹恢复及离线进程链完成 | [offline](06-final-v2-cli-offline-fixture.result.json)、[Windows链](06-final-v2-cli-windows-chain-test.result.json) |

完整日志SHA256：ReleaseSafe为`0bc296af19976d58bcee10e534c4c9f96559a8ba62ea7eb1801a0695db376b46`，Debug为`2ad504b29646ef98057bb2770c0ca18648de131dcda63a41cb39869eb5dddd2f`。源码清单、命令参数、逐步起止时间、退出码及产物摘要见各记录；exe/pdb不提交。资源/RSS/索引成本、Venue在线及平台生产资格仍未取得。

## 实现与验收边界

- EconomicProjection独立保存每单唯一已应用成交量，OMS reported cumulative继续表示交易所报告。累计量严格等于已归档计入量加驻留唯一证据总和；订单历史保留最终累计后才能释放累计槽位。
- 成交批次保存完整资格、原canonical/Core语义、完整经济转换与关联账本，及实际已应用经济摘要的typed认证记录。先发布历史，再权威提交，再回收驻留明细。
- Owner和Gateway承接连续业务根，保留旧订单回执和发送身份，经济归档不释放Unknown、accepted结果或reservation。恢复认证最新资格和完整状态摘要，不自动发送。
- 冷重复无经济副作用，冲突锁存；冷热完整账户覆盖维持既有引用合同，不能通过回收明细缩小应认证事实范围。
- 快照内部累计、完整AppliedFill、原始source及热订单归属交叉校验。重新生成合法外层摘要也不能掩盖缩减累计、孤立条目或篡改证据。

领域决策见[ADR0014](../../docs/adr/0014-preserve-applied-fill-quantity-across-economic-archive.md)。资金费、对账窗口承接和控制历史回收属于07/08。

## 早期候选与失败历史

| 范围 | 实际结果 | 证据 |
| --- | --- | --- |
| 3cc1586d候选完整ReleaseSafe编译 | 退出0；执行栈256MiB | [构建记录](06-rollback-full-releasesafe-build.result.json) |
| 同候选完整Debug编译 | 退出0；尚未执行此完整产物 | [构建记录](06-rollback-full-debug-build.result.json) |
| 同候选Owner成交归档回归 | 9/9，退出0 | [日志](06-rollback-owner-rs.log)、[退出记录](06-rollback-owner-rs.result.json) |
| 同候选完整ReleaseSafe执行 | 546/548，退出1；源码清单无漂移 | [日志](06-rollback-full-releasesafe.log)、[退出记录](06-rollback-full-releasesafe.result.json) |
| 公开安全用例定向Debug复现 | 累计20实际0，退出1；证明真实调度回归 | [红日志](06-safety-fill-red-debug.log)、[退出记录](06-safety-fill-red-debug.result.json) |

完整ReleaseSafe失败定位见[调查记录](06-full-failure-investigation.md)。失败轮保留，不计为完整通过；四分片小规模初始归档、十轮替换及最终恢复本身已完成。

## 最终验收之前的修复记录

安全候选占满后的Fill原子查验已修复。原公共累计20、两候选隔离、高水位和tail恢复定向Debug通过，见[最终原回归日志](06-safety-inline-final-debug.log)、[退出0](06-safety-inline-final-debug.result.json)。新增5场景同样通过，见[边界日志](06-safety-inline-boundaries-debug.log)、[退出0](06-safety-inline-boundaries-debug.result.json)：冷same/conflict、缺费用经济拒绝锁存、权威commit失败、查询不可用时两笔Fill持久背压及checkpoint/recover/retry累计20。

15e3f31fd9a3a1239677af28e8572cf764515f4c8f2cf0569ced2b73d4dc5c47的91份源码清单见[该轮清单](06-final-source-manifest.json)。该轮fmt --check与git diff --check通过；其后栈帧隔离修改尚未重新冻结，因此该清单不代表当前未提交源码。先前9a348505候选因新增恢复夹具和高水位断言修正已失效，未执行最终验收；见[旧清单](06-pre-final-source-manifest.json)。最终验收脚本为[run-06-final-acceptance.ps1](run-06-final-acceptance.ps1)，任何非零退出或源码漂移都会停止后续步骤并保存结果。

旧6aa4145e完整ReleaseSafe为549/549退出0，四分片归档、十轮与恢复及全部成交用例确实通过；记录现保存在[旧完整日志](06-superseded-6aa/06-final-full-releasesafe.log)、[旧退出记录](06-superseded-6aa/06-final-full-releasesafe.result.json)。但仍有旧Gateway合成40960发送证明及8192 reservation的满载夹具，违反用户小规模功能执行要求，因此该轮不计为最新执行口径的最终验收。其Debug已停止，完整日志及已知runner退出-1保留，见[中止记录](06-superseded-6aa/06-final-full-debug.result.json)；被终止子进程的原生退出码未由已停止wrapper保留，不虚构为测试失败或通过。

最新Gateway恢复夹具为99 accepted+1 Unknown、128KiB编码空间，保留恢复、过期权限拒发、持久屏障及SDK零新增；权限夹具为6 reservation/3 position，500观察仍保留。生产40960/8192/500边界改为纯数字检查，六处原生产guard均保留相同==语义及usize总和，常量未改。Gateway定向Debug[22/22通过](06-small-gateway-debug.log)，见[退出0](06-small-gateway-debug.result.json)。独立全src扫描未再发现千单/发送证明/reservation构造；观察用例的四分片各26驻留订单为各25 live+1 canceled，合计100 live/4 terminal，符合每类上限。

15e3f31f四分片定向回归2/2退出0，见[日志](06-final-four-shard-rs.log)、[退出记录](06-final-four-shard-rs.result.json)。完整ReleaseSafe与Debug串行执行，均550/550退出0且各步源码无漂移，见[ReleaseSafe结果](06-final-full-releasesafe.result.json)、[Debug结果](06-final-full-debug.result.json)。四分片初始归档、十轮替换及最终恢复均实际完成；完整套件数量表示测试项数，不表示订单负载。

同源码应用和CLI重建退出0，但64MiB栈应用的`--offline-fixture`退出3，见[失败日志](06-final-app-offline-fixture.log)、[退出记录](06-final-app-offline-fixture.result.json)。最终流水线因此停止，未执行其后模式，不以编译成功判定应用通过。独立对照的256MiB栈CLI两模式退出0，见[offline结果](06-stack-cli-offline-fixture.result.json)、[windows-chain结果](06-stack-cli-windows-chain-test.result.json)，不能代替64MiB应用验收。

当时诊断：原夹具main、runHappyPathInto和healthyRunInto三个静态帧累计68,121,472字节，超过应用64MiB栈；隔离fixture.apply内联后，备用公开apply分支继续引入约22MiB帧。两处隔离后五条轨迹推进至恢复，但`replayReaderInto -> TradingShard.apply -> applyCore`仍叠加约三个22MiB帧，见[旧失败日志](06-stack-isolated-offline-fixture.log)、[退出3](06-stack-isolated-offline-fixture.result.json)、[静态帧记录](06-stack-isolated-frames.json)。该轮只证明栈溢出，不能认定实际订单丢失；后续修复及最终运行见本文最终结果。当时隔离修改的optimization定向Debug为10/10退出0，见[结果](06-stack-rollback-debug.result.json)，不替代最终源码完整验收。

恢复已改为复用`replayReaderInto`已有未发布候选，调用`applyOwnedCandidate`；未可发布错误恢复原状态，原恢复准入旗标、权威错误筛选、逐条事实校验及完整组后发布保持不变，无新增隐藏分配。公共恢复回归以零订单在64MiB栈实际复现旧路径溢出，见[红日志](06-replay-small-red-v3.log)、[wrapper退出1](06-replay-small-red-v3.result.json)（子测试退出3记录在原日志）。新回归最初两次编译错误及一次测试准备调用内联造成的栈溢出均保留在`06-replay-small-red*`及`06-replay-small-green*`日志，未覆盖或计为通过。隔离测试准备交易帧后[64MiB回归2/2](06-replay-small-green-v2.log)、[退出0](06-replay-small-green-v2.result.json)，实际验证完整恢复摘要、持久拒绝锁存、截断输入不发布和恢复后新timer仍被准入旗标拒绝。

用户再次要求不做千单/容量压力，以不超过100个live或terminal单验证全部功能点。诊断后仅恢复小功能验证，不降低检查点频率、不省略恢复断言、不改生产容量限制。该修复阶段未关闭issue/map或提交06。独立Standards和Spec审查及配额guard等价复核见[06-review](06-review.md)，未发现具体P1/P2；随后最终门槛已按新冻结源码实际完成。坏证明/记录关闭分支仅源码复核，未专门注入。中间新增夹具单Fill恢复失败和早期编译失败的原日志曾被覆盖，已明确记录缺失并保存失败摘要；不会将这类摘要计为最终运行证据。

不授予容量压力、资源/RSS/索引成本、Venue在线或平台生产资格；本票没有部署或真实下单授权。

## 恢复及文件栈修复后的最终候选

五轨迹应用64MiB栈首次恢复通过后，Windows离线链又在Gateway启动约32MiB编码帧嵌套File发布约32MiB拼接帧时溢出，见[失败日志](06-replay-app-windows-chain-test.log)、[退出1](06-replay-app-windows-chain-test.result.json)。上游Python EOF和IPC断开是该子角色栈溢出的后果，不记作实际丢单证据。

Gateway现在可借用调用方独立快照缓冲区；原启动/检查点接口共用编码及持久协议，未配置缓冲区的旧栈路径单独never_inline。Windows两类Owner通过init.gpa明确分配32MiB并保留至生命周期结束，失败errdefer释放；Gateways恢复保留借用指针，快照只编码业务字段。文件发布改为96B原头及原payload写入同一临时文件，再一次sync；原snapshot_sync故障点、rename、目录同步、manifest及旧snapshot加载保持。独立加载scratch不与待发布payload别名。

现有公共Gateway回归[Debug22/22通过](06-bootstrap-checkpoint-buffer-debug.log)、[退出0](06-bootstrap-checkpoint-buffer-debug.result.json)，覆盖短缓冲区拒绝、调用方覆盖buffer后恢复、重复检查点及accepted/Unknown零重发。文件公开目标回归[ReleaseSafe5/5通过](06-file-snapshot-split-targeted-releasesafe.log)、[退出0](06-file-snapshot-split-targeted-releasesafe-result.json)，覆盖轮转、故障、同屏障重复发布、两代fallback及重开，零订单且源码文件无漂移。两轴补审未确认具体P1/P2。

最新91份业务源码冻结为`c508f89c8c6faae0c428e3e2195df957d4377a453a673ee772edec2c9d2b17b4`，见[新清单](06-final-v2-source-manifest.json)。64MiB应用[五轨迹offline退出0](06-stack-shared-offline-fixture.result.json)、[Windows离线链退出0](06-stack-shared-windows-chain-test.result.json)，原始输出见各同名前缀log/stdout.log。离线链的预期坏输入拒绝、历史模拟/磁盘恢复、OKX离线角色及fencing测试通过；报告仍明确`windows_process_chain_verified=blocked`、`read_only=not_run`、`demo_live=not_run`及`production_qualification=false`，不据exit0提升资格。

冻结后的独立[最终验收脚本](run-06-final-v2-acceptance.ps1)输出`06-final-v2-*`，不覆盖15e3旧550/550或任何失败日志。新源码四分片回归[2/2退出0](06-final-v2-four-shard-rs.result.json)，源码无漂移；完整ReleaseSafe于2026-10-14T09:19:25Z开始、09:36:45Z完成，[551/551退出0](06-final-v2-full-releasesafe.result.json)，源码无漂移，原始[完整日志](06-final-v2-full-releasesafe.log)SHA256为`0bc296af19976d58bcee10e534c4c9f96559a8ba62ea7eb1801a0695db376b46`。四分片归档、十轮替换及最终恢复在该完整套件再次通过。

同一源码完整Debug[编译退出0](06-final-v2-full-debug-build.result.json)，其后串行执行[551/551退出0](06-final-v2-full-debug.result.json)，源码无漂移。应用、CLI按相同冻结源码再重建并运行两模式，各退出0，记录见本文最终表。issue06已resolved，07 blocker解除；本代理按用户要求在06收尾后停止并交接。[ReleaseSafe进程资源观察](06-final-v2-releasesafe-resource-sample.json)仅为小功能完整套件的一个时点，不证明任何千单资源预算或索引成本。

## issue06完成条件与最新实际运行对应

以下编号均来自c508f89c完整ReleaseSafe551项日志，非旧候选成绩；同源码完整Debug也全部通过，最终全部门槛已完成。

| 完成条件 | 最新公共运行及断言 |
| --- | --- |
| 独立唯一成交累计，明细回收不归零 | 430：恢复后唯一已应用量为2、OMS reported仍为0；431/432：拒绝合法外层摘要但内部累计/驻留证据不一致的快照，十轮归档保留每单唯一累计 |
| report/Fill合法先后、部分成交、第三资产费用 | 432：两单交替report/Fill先后、十轮部分成交及最终恢复；433：重复第三资产fee/rebate及精确native余额恢复 |
| 冷same无副作用、conflict锁存、移出后仍验证归属 | 432/435：冷same、费用/返佣conflict、订单/成交/订单连续根及旧归属查证 |
| 经济状态与账本守恒，失败不部分提交 | 429：读取完整归档资格并核对账本摘要及费用posting；434：历史发布、decision提交、Gateway追加/检查点故障，旧或新完整经济投影恢复 |
| 多窗口、检查点/replay、故障及零重发 | 432/434/435：跨窗口checkpoint/replay、故障恢复、相邻业务根、SDK发送次数不增加 |

独立只读验收核对确认以上映射。限制仍如实保留：第三资产归档场景未逐条读取native ledger posting，完整资格的全ledger收集另有公共Core归档用例及源码核对；Owner坏proof/record关闭未专门注入，不把源码审查记作实际运行。
