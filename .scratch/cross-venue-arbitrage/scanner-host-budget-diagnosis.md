# 两项Python全量失败：checkpoint发布预算诊断

诊断完成日期：2026-11-08（Asia/Shanghai）。

基线：Ringwin策略分支`spread-arbitrage-strategy-python`，`f3341d72`。来源：用户要求查清内存历史实施后Python全量2项失败的根因。离线诊断，不连接Venue、不部署、不交易。

## 原始症状与复现

- `WebInstanceTests.test_secondary_config_keep_changes_only_target_and_peers_recover_from_original_repositories`：配置Keep候选验证失败，`config_transition.status=rejected`，原日志理由为`candidate callback or warmup budget exhausted`。
- `WebInstanceTests.test_successor_lost_commit_ack_stops_and_reopen_cannot_restore_predecessor`：预期`unknown`，实际`rejected`。原全量日志未包含该次拒绝理由；本轮捕获到相同断言失败及具体原因。
- 两项原样串行循环10轮／20次均通过，因此不能用单次重跑通过排除问题。收窄到真实候选`_run`，保留真实Web、签名包、Zig适配器、Python Host及DurableStore，循环创建全新候选仓库；两个诊断进程并行以提高I/O尾延迟复现率，没有修改回调／预热预算。
- Keep轨迹：`stage.jsonl`中PID44956于单调时刻858767.718收到initialize、validate、checkpoint阶段；下一次read预算1.0秒，于858768.734超时；候选Stopped，理由与原失败一致。
- Successor轨迹：`successor.jsonl`中PID44620于858764.765完成replay／validate并进入checkpoint，1秒后read超时，候选Stopped，继而`successor_transition=rejected`；原测试在`rejected != unknown`断言处失败。此时尚未调用begin／commit_successor，因而没有走到丢失提交ACK的注入点。
- 诊断命令与轨迹位于被忽略的`.scratch/build/host-budget-diagnosis/`：`repro.py`、`stage.py`、`successor.py`、`trace.py`。扩大单个HTTP请求中的候选循环时将诊断客户端超时从30秒增至180秒，未更改被诊断的1秒callback／10秒warmup预算。首次长循环撞到客户端30秒超时及清理错误的记录不作为根因证据。

## 根因

`InstanceManager._run`和`_run_shared`把所有native进度阶段一律切到`max_callback_ns`；测试包此值为1秒。Zig发出的`checkpoint`阶段不仅包含Python快照回调，还包含codec校验后的`Repository.publish`。后者需要DurableStore的commit、seal、snapshot及rotate，包含文件同步，其I/O尾延迟会超过1秒。运行期`_exchange_io(checkpoint=True)`也存在同样混用。

首次Ready的Python Host已在返回STRATEGY_RECOVERED之前完成快照、validate及restore往返，首次checkpoint复用这份已验证state，仅编码并发送，不再执行策略回调（`strategy_candidate_host.py`的首次REQUEST_CHECKPOINT分支）。因此压力复现的验证后超时暴露的是持久发布／IPC调度阶段被套用回调预算；资源压力是触发条件，预算归属错误是代码缺陷，不把某一具体磁盘调用的耗时当作已单独测量。

因此实际失败是候选Ready之前的checkpoint持久发布超时，状态机按预期拒绝未Ready候选。第二项不是“丢失ACK之后应该unknown却被错判”，而是测试没有抵达该注入点；旧断言未输出拒绝理由，掩盖了前置失败。原日志不足以唯一反推第二项当时的理由，本轮压力复现和确定性延迟回归确认了这一可触发相同症状的共同缺陷。

## 修复及可检查边界

- Zig仅在已收到并校验checkpoint内容后发送`publish_checkpoint`，随后才进入DurableStore发布；不把尚未完成的Python回调标为存储阶段。
- 单Host／共享Host预热的发布阶段使用既有`max_warmup_ns`剩余总预算；运行期checkpoint发布以本次命令开始时间加同一有界预算为绝对截止点，不无限续期。
- 回调仍使用原`max_callback_ns`；运行期拒绝非checkpoint命令或重复publication标记；旧native组件不发送新标记时保持原保守处理。没有改核心schema、权威状态或真实交易许可。
- 原丢失ACK测试新增“确实执行commit_successor注入”的断言，并在失败时包含完整合成回执，避免再把前置拒绝混成ACK状态错误。

## 回归证据

- 新增真实Web公开接缝测试`test_checkpoint_publication_does_not_consume_strategy_callback_budget`：在OS pipe边界延迟真实publication回复1.2秒，保留真实Ready／checkpoint／核心确认内容，覆盖首次Ready、配置切换前快照、新候选Ready及切换后快照。
- 新native阶段标记加入、Python预算修复之前运行该测试：8.520秒，`Stopped != Ready`，理由`candidate callback or warmup budget exhausted`，见`red.log`。
- Python预算修复后：新增延迟回归、原失败两项和回调死循环终止回归，共4项通过，54.140秒，见`green.log`。这同时确认发布可以超过1秒且真正回调仍受限。
- 最终模块回归：`python -u -m unittest test_strategy_instance`，71项，70通过、1跳过，604.063秒，见`strategy-instance-suite.log`。覆盖共享Host、配置／代码切换、恢复、撤权、回调隔离与新增发布延迟；本轮没有重跑整个仓库372项或Zig889项，原全量失败记录保留。
- Zig候选正式入口ReleaseSafe构建通过：`zig build-exe src/strategy_candidate_main.zig -OReleaseSafe --stack 67108864 "-femit-bin=zig-out/bin/ringwin-strategy-candidate.exe"`。
- 双轴静态复核：Standards无硬性违规／P1/P2，Spec无P1/P2或本轮缺口。审查未执行运行验收。

另一次并行诊断出现过真实输入超过既有50毫秒新鲜度门槛而拒绝，属于不同症状，不作为本次checkpoint超时证据，也未放宽该门槛。没有据此宣称生产容量、连续24小时运行或真实行情资格。
