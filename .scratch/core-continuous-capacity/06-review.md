# 06 两轴审查与修复进度

基线fd1513e8，当前WIP；本文件不代替最终冻结源码验收。

## Standards

独立审查确认P1：独立累计量未与驻留唯一成交证据交叉闭合，重新生成合法快照后可缩减累计并绕过后续超填判断。已补累计严格等于归档计入量加驻留唯一总和、完整AppliedFill与canonical证据的身份/数量/摘要匹配、原始source内容校验和恢复累计条目必须归属热订单。新增公共快照回归对缩减/删除累计、修改证据摘要及孤立累计分别验证拒绝，并验证归档明细已回收后缩减累计仍被拒绝。

独立审查确认P2：新增Gateway经济根承接使用隐式page_allocator。已移除该路径的heap分配，并避免整份Gateway栈复制。单写者仅保存原根绑定/count和durable cursor；失败回滚这些字段、保留安全锁存，成功完成提交和checkpoint才返回。独立聚焦复核确认本路径没有其他被遗漏的内存变更；已持久但checkpoint失败的事实仍由恢复重放承接，不能原实例覆盖序号。

## Spec

独立审查确认P2：Core来源成交原先热态可认证的经济摘要，归档后使用错误typed键导致合法冷对账失败。归档批次新增fill_economic_digest认证条目，保留实际已应用的32字节摘要；冷对账查询此typed身份并校验摘要字节的认证hash，兼容canonical与Core既有摘要，仍必须same证明和完整覆盖。

## 尚待验证

子代理实施因使用额度限制中断，Root接手。最新累计承接版本[Owner八项日志](06-archived-total-owner-rs.log)与[退出0](06-archived-total-owner-rs.result.json)覆盖第三资产原始opening余额、快照拒绝、十轮、故障、谱系及旧兼容全部通过。新增真实Core Fill的热对账→归档→冷对账→恢复公共回归正在验证。最终完整两模式、CLI、最新两轴回查、证据及06提交仍待完成；不授予压力、资源或生产资格。

后续真实Core公共回归已与全部Owner用例一起[9/9通过](06-review-fixed-owner-rs.log)，[冷覆盖回归1/1通过](06-review-fixed-cold-coverage-rs.log)，源码125ba91e。两轴分别复核46db8d0b候选，原P1/P2无剩余具体问题。Gateway随后缩小回滚范围，当前候选见[3cc1586d源码清单](06-rollback-source-manifest.json)，正重新执行Owner故障回归并编译完整两模式；旧46编译产物不执行、不作为新候选验收。

## 完整执行发现的安全调度回归

3cc1586d完整ReleaseSafe最终546/548退出1，清单匹配。两项失败见[调查记录](06-full-failure-investigation.md)：四分片旧golden已在经济与多恢复路径断言通过后按当前格式更新；公开安全用例真正暴露双候选占满时Fill冷查验背压而未应用。现采用仅Fill原候选与可用证明的单权威输入，既有候选不变；不可用仍保留原始时钟、归属和deferred admission，恢复白名单需允许Fill。

独立Spec复核新同步路径发现P2：无效证明/记录错误没有像普通查证路径一样关闭Owner。已改为closeAdmission并返回InvalidHistoryProof；再次只读复核未发现其余具体P1/P2，检查了原输入/当前根/高水位重建、defer恢复两候选、经济失败锁存及紧凑编码边界。公开原安全用例及5种同步场景已定向Debug通过；最后的Fill延迟入队恢复验证和最终冻结完整验收仍在进行。

## 最终候选6aa4145e

新增延期Fill的订单归属和快照类型白名单已补齐；两笔各10的Fill一起持久背压，checkpoint/recover后按原序重试累计20，仍保留主及安全候选。最终公开原安全回归和5边界定向Debug均退出0，记录见06-evidence。Standards由独立scope_inventory回查，未确认具体P1/P2或硬规范违规：新增路径无隐藏分配，原候选/proof同一权威输入，只有提交成功才发布经济状态。Spec由独立review06_spec回查，先前无效proof P2已修，无剩余具体P1/P2；坏证明/记录专门故障注入未执行，关闭分支按当前源码确认。

格式及差异检查通过，当前91份冻结身份6aa4145e。完整两模式及最新应用/CLI尚待脚本实际终态；审查通过不代替测试，不授予压力或平台资格。

## 小规模口径最终补审15e3f31f

6aa4145e仍有两处旧Gateway大夹具：40960 dispatch证明与8192 reservation。Root停止验收并保留全部旧产物/日志，改为100条恢复证明、6 reservation/3 position；500观察仍保留。Shared dispatch及reservation/position六个guard抽取为私有纯数值谓词，保留原==与usize求和语义，生产常量未变。定向Gateway Debug22/22退出0。

独立Standards和Spec均确认无新增具体P1/P2：恢复计数、SDK零新增、提交屏障不变和过期权限拒发仍在；权限夹具保留独立新增reservation与position不重复增加，观察溢出仍锁存。独立全src扫描未发现其它千单构造。四分片观察用例各26实际由25 live+1 canceled构成，总100 live/4 terminal，符合每类上限，不削减观察。

当前最终91份冻结15e3f31f，两模式及应用/CLI按该身份重新执行。旧6aa549/549只保留为历史功能运行记录，不能借其授予最新小规模执行验收或压力/资源资格。

## 应用恢复栈帧修复补审

15e3f31f完整两模式均550/550退出0，但64MiB应用offline夹具栈溢出，未取得最终验收。夹具apply及公开Core/Venue备用分支隔离内联后，恢复仍嵌套三份约22MiB候选。Root改为复用replayReaderInto已有候选及公开applyOwnedCandidate，错误且不可发布时重置，完整事实组核对后才发布。

独立Standards复核相对HEAD fd1513e8的当前06全差异，无剩余具体P1/P2或需报告的判断性smell：无隐藏分配，恢复fence和可发布错误保持，两个never_inline不改变参数、返回或输出借用归属。独立Spec复核同差异及新增Fill文件，无剩余具体P1/P2：归档量加驻留量等式、完整经济资格、先提交后回收、两候选保护、accepted/Unknown零重发及每类订单不超过100均保留。

公共恢复回归已在64MiB栈实际红→绿，最终2/2退出0；完整恢复、持久拒绝、截断不发布及准入旗标均有断言。第一次补丁后测试准备调用内联仍导致溢出的失败也保留；未以失败产物充当通过。应用原复现和最终冻结全套仍待实际结果，审查不代替运行、不授予压力或生产资格。

## Gateway与文件发布栈修复补审c508f89c

64MiB应用恢复通过后Windows离线链在Gateway启动与File快照拼接缓冲区叠加时溢出。Root补入Gateway可借用调用方独立buffer的启动/检查点接口，旧栈fallback隔离；两runtime Owner显式分配、失败及退出释放。File发布由scope_inventory实施96B header加原payload写同tmpfile再sync，无新分配，不改格式/预算/故障及manifest顺序。

独立Standards再次复核，未发现具体P1/P2：Gateway借用生命周期明确，init清空且恢复保留但快照不编码该字段，checkpoint失败仍锁存，fallback独立never_inline；两Owner无隐藏分配，File两次write加一次sync保留提交责任。独立Spec再次复核，无新增P1/P2：恢复重建accepted/Unknown不发送，写入或同步失败不发布部分快照，同屏障身份检查、旧代加载及manifest失败回滚保留。

实际Gateway22/22 Debug及文件5/5 ReleaseSafe已通过，日志/结果见06-evidence。91份最新冻结c508f89c，完整ReleaseSafe/Debug串行各551/551退出0；最终应用64MiB及CLI256MiB按同源码重建、各两个离线模式均退出0。逐步源码无漂移，12条命令和四个产物的46项核对通过，06resolved。

独立验收核对将五条Acceptance逐条对应c508完整RS公共运行及实际断言，随后同源码Debug全部通过。坏proof/record关闭仍仅源码复核；第三资产归档记录未逐条读取native ledger posting，完整账本资格另有公共Store/经济用例与源码验证。限制在06-evidence明确保留，不提升任何压力/资源或生产资格。用户要求06关闭后停止，07交接给另一代理。
