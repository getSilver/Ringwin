# 10 Windows 文件持久化与持续恢复

状态：Windows小规模文件功能验收通过。冻结v3完整ReleaseSafe/Debug各624/624，实际64MiB应用与256MiB CLI各十轮归档、30个独立进程及四路500组合文件恢复，570项证据审计通过。目录耐久性、容量/压力和生产资格仍未取得。

工作树`D:\github\Ringwin-core-continuous-capacity`，分支`codex/core-continuous-capacity`，基线`4ea4c3ee3f6bfc4a822196649fb011e3b5f0dfa2`。当前候选114份源码SHA256 `f1e1a54a06c15f62fb9e082bfad642d1ada0165d3936ba9f93470637b885df42`，见[manifest](10-final-v3-source-manifest.json)。首轮73532d4a旧源码、六份producer及identity共122文件已精确封存为[旧输入归档](10-v1-frozen-inputs.json)，两次拆壳候选也分别封存，不覆盖失败数据集。日期2026-10-16。

## 业务与文件边界

`windows_capacity_acceptance`从第一条bootstrap起使用真实WindowsFileAdapter，分别持久化四个Owner的decision/control/RawIngress流；恢复不接收父进程的内存快照。前三片逐轮place/cancel、终态查证、业务归档、冷accepted查证、checkpoint和关闭文件。第四片保留真实两品种开仓、平仓及独立减仓hedge后的非零经济状态，同时有3个partial、PendingCancel、resting、Unknown和3个filled终态。Unknown来自模拟发送后丢响应的真实Gateway durable attempt。

四片使用portfolio11–14、同account2、独立decision domain1–4及独立stream命名空间。共享账户摘要从真实TradingShard生成，持久化到独立File Coordinator；gross-1账户ceiling拒绝，不能用全局或其它分片余量替代。推进后的风险摘要通过公共Writer持久发布，恢复仍为RecoveryOnly，不授新lease。正常链驻留9live/3terminal，单次顺序推进至多10live/4terminal；没有千单或压力负载。

`windows_observation_file_acceptance`复用09的公开Feed/Venue/Owner/Gateway业务helpers，从bootstrap即接File。四路各125个独立组合，75spot/50perpetual；实际持久化并核对做市90live、4个spot/perpetual funding类别双腿、1个跨Venue反向双腿。每片25live/1terminal，全夹具100live/4terminal，seed合计108次模拟发送。各组合的Venue、产品、完整instrument身份、归属、持久ClientOrderId及经济方向由可执行代码逐项检查；workload.json保留500身份映射。第四路是离线模拟容量，不证明第四家协议接通。

每个实际app/CLI分别启动新seed/recover/advance进程；十轮后要求完整canonical/economic、账本摘要、余额、库存、成本、费用、占用、游标、next identity、业务根及Coordinator状态相等。normal recover还核对实际所有文件名、长度、SHA256和allocated size不变。RawIngress经公共重放准入，重复已应用Fill不产生新经济副作用；accepted和Unknown恢复发送均为0。

独立seed副本用于单次shard0 Owner.apply的发布前/后终止。父进程必须收到整行精确barrier/digest marker才终止其自有子进程，再启动新reader核对旧/新完整状态；另三片不变。该检查不声称跨分片原子事务，也不模拟断电或清空设备缓存。

## 故障与生产修复

`windows_capacity_fault_acceptance`每个场景最多2live/0terminal：Owner写入/同步/发布/回收9项、Gateway控制检查点3项、真实文件缺段/同长bitflip/截断/manifest损坏4项、经Store认证的错误Core schema/artifact2项，共18项。命名错误明确标为adapter hook，不能称真实OS ENOSPC/EIO/短写。错误schema和artifact的外层文件完整性有效、Store physical ready，随后公共Core恢复拒绝；不是任意改字节后靠CRC失败冒充语义身份验证。

实际发现并修复`durable_store.recoverOrderHistoryImpl`的正常首次历史恢复误关门：从未发布历史时两份sidecar均不存在，原先返回FileNotFound并关闭Store，Coordinator恢复后不可继续写入。现在仅在objects和roots都明确不存在时返回正常OrderHistoryUnavailable并保留gate；已发布roots缺objects及其它I/O仍失败关闭。若权威snapshot已有history_root，两份文件均丢失仍由Owner/Coordinator拒绝，不能静默变成首次。没有改变schema、身份或生产容量。

最小公共Store回归先实际red，再验证无历史恢复、真实publish/recover和删除已发布objects后的关闭；修复后1/1。混合File定向1/1、观察File定向2/2、fault定向3/3（18场景）通过。它们均为开发证据，最终资格只认同一冻结源码的完整套件与新进程结果。

## 开发期失败与预检

全部原始失败和未执行范围保留：旧cache的build.exe缺失；fixture误用test-only fencing工厂的app编译失败；64MiB app在Gateway栈scratch加File snapshot读取时溢出；File直入选单缺activation之后的新事实；Coordinator旧风险摘要及无历史误关闭；回归fixture误用control域Command key；Python3.9不支持zip(strict=True)。相应`10-*`原始log/result仍在，不能只封存成功样本。

栈溢出通过夹具调用已有caller-owned heap buffer API修复，未增大应用64MiB栈。新的公开reference_price提供真正activation后的事实，未绕过策略游标检查。zip使用先验证长度再逐项比较，未截短恢复断言。

[预检](10-preflight-v2/summary.md)实际64MiB应用已通过12个独立子进程，包含一次归档推进、完整恢复、两个真实进程终止及四路500观察seed/recover。之前Python兼容性失败的[原始目录](10-preflight-v1/identity.json)单独保留。预检不替代最终十轮和完整套件。

Capture拒绝覆盖既有label，异常/超时保存结果；实际existing-prefix、1秒timeout、spawn failure三个probe通过。每阶段前后冻结Zig源码及Python依赖，消费exe前后与构建时SHA绑定；外部exe SHA不匹配在启动前拒绝且数据集不变。

## 平台与资源观察

本机Windows10 Enterprise LTSC 10.0.17763、NTFS、i5-4200U（2核4逻辑）、约8.48GB RAM及SATA SSD；实际只读元数据见[host](10-windows-host.json)，采集失败也原样记录。固定Zig `0.17.0-dev.315+5b647b792`。schema为journal39/state43/registry37，Core artifact identity1不是exe SHA，二者分别验证和记录。

[文件语义核对](10-file-semantics.md)和[native probe](10-file-semantics-nativeprobe/output.log)实测普通文件sync/flush、替换及重开成功；两代目录FlushFileBuffers均返回0/error5，现有代码忽略目录flush结果。目录耐久性不合格，不能将功能重开解释为断电保证、Linux等价或Windows生产资格；未提升权限、修改ACL或flush整个卷。

GetProcessMemoryInfo每100ms观察直接子进程working set及OS报告peak。编译器、完整测试、Python编排和每个真正app/CLI子进程分别记录；Python父进程RSS不冒充app总RSS。samples.jsonl的allocated bytes只覆盖常规数据文件，不包括目录、MFT或journal开销。恢复文件清单同时保留logical bytes和原生FileStandardInfo allocated size。

`recovery_ns`仅为Owner恢复部分；进程result elapsed包含进程启动、恢复/业务、JSON及完成后的文件清单核对，不是裸apply、commit或p99延迟。队列值是命令末尾adapter resident样本，未采瞬态高水位。PE栈预留为app64MiB、测试/CLI256MiB；实际线程峰值栈未测。千单容量、压力、RSS预算、索引成本及目标平台性能明确deferred，观察值不称达标。

## 最终验收与复现

`10-final-v1`串行完成完整ReleaseSafe/Debug各623/623，同源码app/CLI构建和各两个离线模式均退出0；随后app文件进程链在advance-02栈溢出退出3，外层流水线失败，CLI十轮未执行。原始[失败](10-final-v1-app-processes/advance-02.result.json)及其stdout/stderr、文件清单和数据集均保留。

当前修复Owner.apply冷查证递归叠加的大栈帧：将事务candidate及持久提交后半段移入独立noinline helper，policy/cold staging在薄壳中完成，不提高64MiB应用栈、不绕过历史证明。首个Owner拆壳候选（ab45808f；64MiB应用21efa0f7）也实际在advance-02失败：原OMS路径已越过，但canonical accepted report进入confirmPendingReplacement，即使没有replacement，函数入口仍预留完整candidate。该次完整源码另封存于[首修源码](10-owner-stack-first-fix-frozen.json)及zip，原始[失败](10-owner-stack-green-v1/advance-02.result.json)保留。继续将replacement查找和blocksNewSend检查保留为薄壳，仅确有replacement时进入原candidate后半；不改变proof之后的嵌套rollback基准，不把outerprevious代入。两个函数的事务后半保持原语句顺序。

第二次拆壳候选c29cba9a在真正64MiB应用中越过上述栈溢出，但advance-02最终报InvalidArchiveDescriptor；四个交易分片本轮均已完成，失败出自共享账户夹具：摘要不变时没有新committed tail，却仍无条件checkpoint并旋转空归档。Store拒绝空descriptor符合合同，不放宽Store检查。候选完整源码另存[第二修源码](10-owner-stack-second-fix-frozen.json)及zip，原始[失败](10-owner-stack-green-v2/advance-02.result.json)保留。最小回归先变化、再相同摘要，实际复现同一错误；夹具仅在publication sequence确实前进时checkpoint，真实变化仍提交并恢复一致。未用新造heartbeat填充空tail。

新候选114源码f1e1a54a已冻结，定向回归通过2/2，格式和diff检查通过；10-final-v3在2026-10-16 17:43本地时间启动。v2只生成了c29源码manifest，没有启动流水线；其审查结论属于旧候选。v3先实际运行两产物十轮链，再执行完整两套，不能沿用v1绿色套件作为新源码通过证据。

v3实际app与CLI构建、各两个离线模式均退出0；[app进程链](10-final-v3-app-processes/summary.md)和[CLI进程链](10-final-v3-cli-processes/summary.md)各10轮/30进程通过，包含500组合File夹具。新源码ReleaseSafe/Debug完整各624/624通过，执行耗时分别2792.961秒与5393.196秒；Debug于20:24完成，约89.9分钟。长耗时来自包含旧历史连续性测试的完整回归，不能与新File子进程恢复耗时混用。十二个最终capture均退出0，source/producer漂移均为0，四产物构建与消费SHA一致，实际PE栈预留仍为64/256MiB。

[最终审计](10-final-v3-audit.json)570项通过；[Windows证据包](10-final-v3-windows-evidence/summary.md)已封存60个真正原生子进程记录、57项故障/平台/未执行观察与36个非零历史capture清单。57项不是57个通过案例：含两mode各18场景、真实owned-process终止、启动前artifact拒绝、not_run及目录flush失败。原始失败、错误期源码zip和本地物理数据均保留。独立[Standards](10-v3-standards-review.md)与[Spec](10-v3-spec-review.md)分别复核，不将旧候选结论替代本轮结果。

| 小功能资源观察 | app | CLI |
| --- | ---: | ---: |
| OS报告peak working set最大样本，bytes | 276848640 | 276844544 |
| 主链数据初始/十轮后logical bytes | 6107476 / 7920172 | 6107476 / 7920172 |
| 主链十轮后常规文件allocated bytes | 8146256 | 8146256 |
| recover整进程elapsed范围，秒 | 1.745–2.655 | 1.767–2.576 |

allocated观测无缺项，但不包括目录、MFT或journal。命令结束时adapter queue均为0，不代表瞬态峰值；完整测试进程peak分别1171505152/1284022272 bytes，不作为app预算。完整样本与计时口径见[resources](10-final-v3-windows-evidence/resources.json)和[samples](10-final-v3-windows-evidence/samples.jsonl)。所有预算/性能仍未取得资格。

最终证据目录最低文件为identity.json、workload.json、samples.jsonl、faults.jsonl和summary.md，另有每进程命令、PID/时间、stdout/stderr及完整文件哈希清单。二进制及物理数据集保留在本地，版本控制封存身份、清单、原始日志及报告。

## 验收条目交接

| issue10 条目 | 当前直接证据 | 资格边界 |
| --- | --- | --- |
| 真实File公共业务链与新进程恢复 | app/CLI各10轮、30进程，三类别500组合及混合生命周期；每次recover完整authority及物理清单对比 | 各夹具跨全部片live/terminal各不超过100；不是千单压力 |
| 故障、完整状态及零重发 | 两套产物各发布前后指定阶段终止；ReleaseSafe/Debug各18故障/拒绝场景；完整账本、占用、游标及摘要比较 | hook注入不称真实OS写盘错误，单片发布不称跨片事务 |
| 身份、资源、失败保留 | source/producer/四产物构建消费SHA、host/schema/种子、每个命令与PID、原生RSS及文件allocated size；旧失败源码zip和原始结果；570项audit及证据包 | 瞬态队列高水位、实际栈峰值和索引成本未测 |
| 票01文件语义及独立Windows交接 | 文件语义核对与native probe，真实File重开与checkpoint；与Linux票11分离 | 目录flush实际失败error5；断电耐久性、容量/资源预算与性能资格未取得 |
| 限定操作及不授生产资格 | 全部CLI为offline/simulation、自有文件夹具及自有进程终止；qualification字段始终false | 无线上交易/凭证/部署/破坏性断电；dump、NodeFence、完整Windows生产资格未测 |

复现须使用同一源码树、固定编译器与新的prefix，不覆盖既有结果：复制冻结manifest为新prefix的source-manifest.json，再运行`python .scratch/core-continuous-capacity/run-10-final-acceptance.py <new-prefix>`和`python .scratch/core-continuous-capacity/audit-10-final.py <new-prefix>`。所有实际逐命令参数在result.json中，File CLI另可直接按该产物SHA运行run-10-file-processes.py。

本票不授权部署、Demo/Testnet/生产下单、凭证、目标机破坏性断电；不证明转储保护、外部NodeFence、完整Windows生产资格或Linux票11。issue12仍等待双平台证据。
