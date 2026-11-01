# 11 冻结合同端到端证据

验收工作树 `D:/github/Ringwin-strategy-package-03`，分支 `codex/strategy-package-03`。
实施基线 `1b096a51c2a390bfab3e0223d766265ade482c6f`；冻结被测提交
`906b8d8fe74a7e4c5fcfe07b9bad007128db92a4`。初始冻结
`c1911755d691f500b3181eef8182106e43488361` 的身份另存
[11-freeze-initial.json](11-freeze-initial.json)；最终测试配置显式增加连续链的有界时限，
产品执行源码不变。后续证据提交不改变最终被测执行源码。

## 身份与复核入口

[11-freeze.json](11-freeze.json) 绑定 Git tree、268 个执行源码/测试/工具文件的逐文件
SHA-256 与有序清单摘要、Python 解释器身份及平台/工具版本。环境为 Windows
10.0.17763、Python 3.9.18、Zig `0.17.0-dev.315+5b647b792`、Node v24.16.0。
没有 build.zig.zon、Python requirements.txt 或 npm lock；本波 Host 依赖由实际
签名 runtime-lock 及安装文件清单冻结，不能从当前全局 site-packages 推断依赖。

两条连续验收输出 `CONTRACT_E2E=` JSON，包含每次 Ready/Trading 的实际 Web 结果、
实例/定义/配置/组合身份、checkpoint/游标/会话、最终记录，以及四个签名发布 manifest
和安装目录内全部文件的大小及 SHA-256。因此包、Host 脚本、解释器、标准库 zip、DLL、
配置/state schema、索引和原生构建清单均绑定实际被测字节。临时包目录在测试后清理；
报告保存身份与签名描述，不承诺保留可部署制品。签名使用既有离线测试 key，不是发布批准。

复跑命令（仓库根目录；须先有同一源码的 ReleaseSafe 构建产物）：

```powershell
zig build -Doptimize=ReleaseSafe --summary all
zig build strategy-authority-probe -Doptimize=ReleaseSafe --summary all
python -m unittest discover -s python -p 'test_*.py' -v
node tools/verify-strategy-package-ui.cjs
```

## 连续生命周期与范围

新增 [test_strategy_contract_e2e.py](../../../python/test_strategy_contract_e2e.py) 只复用
现有签名安装器、已认证 Web、受限 Host 和实际 Zig node/core 测试接缝；产品代码不变。

- Python：安装登记（无资格、无权）→ 创建 Ready → 关闭/重开后端 → 同身份无权恢复，
  generation 增长 → 显式启用 → 输入追赶 → Keep 更新至 ConfigVersion 2，参数改变，
  Ready 等待启用 → Keep 版本 3 恢复一个事件的预热配置 → 新定义 Rebuild Successor →
  原签名发布 ForwardRollback 的另一个新 Successor → 每次分别显式启用 → 暂停。
  两次接替重试均返回原结果，保留 VirtualPortfolio，不复活前任。
  使用观察包以保持责任闭合；实际 OrderIntent/完整 IntentGroup、Gateway 与迟到拒绝
  由同一冻结源码的既有专项测试验证，不能把观察链说成产生真实订单。
- 原生：签名 v2 安装 → 静态观察策略创建、实际 ReferencePrice 回调 → 未获权时关闭/
  重开后端 → 同节点完整日志重建为无权 Ready → 显式启用 → 参数更新明确拒绝且原绑定/
  权限保持 → 替换与 ForwardRollback 创建不同 Successor → 分别显式启用 → 暂停。
  该定义没有同实例参数转换实现，不宣称原生 Keep/Rebuild 参数更新成功。
  双定义节点由现有验收 helper 在临时源码副本编译，清单及二进制哈希在实际安装文件中；
  第二定义不是新增交付策略。后端重开不等于节点进程/断电/热备恢复。

## 合同第 7 节向量映射

下表测试名称均可在冻结源码及完整 verbose 日志中检索。R 表示
`test_strategy_package_release.PackageReleaseTests`；W 表示
`test_strategy_instance.WebInstanceTests`；N 表示 `test_native_strategy_instance.NativeWebTests`。
子票只标所有权；是否执行以日志为准，不由 resolved 状态推断。

| 合同向量 | 实际测试/证据入口 | 负责票与边界 |
|---|---|---|
| 安装未 EnableTrading | 两条连续链的 Ready、core orders=0 与独立启用断言；W `test_candidate_intents_consume_sequence_but_cannot_enter_admission` | 03/04/06/09；离线 |
| manifest/模块/依赖篡改、同身份异内容 | R `test_invalid_signed_packages_do_not_install_or_register`、`test_same_identity_cannot_bind_new_content_and_install_fault_keeps_current`；W `test_installed_runtime_tampering_is_rejected_before_launch` | 03/04；含实际安装拒绝 |
| 路径/链接/JSON/未知字段/容量 | R `test_invalid_signed_packages_do_not_install_or_register` 的 24 个子向量；Windows junction 专项 | 03/04；无部分登记 |
| 同名入口覆盖 | W `test_dirty_parent_environment_and_import_path_do_not_reach_candidate`、`test_shared_host_keeps_same_module_names_in_different_packages_separate`、`test_undeclared_transitive_import_file_is_rejected_before_launch` | 04/10；实际 Host |
| Host/ABI/wire/registry/锁不兼容 | R invalid-signed 的 compatibility/tampered-runtime；R `test_release_registry_identity_must_match_the_approved_bundle_runtime`；N `test_native_runtime_inventory_mismatch_and_closed_gate_refuse_authority`；核心 `supervisor compatibility, timeout, restart and stale-session fencing` | 03/04/09；核心项复用 10 原始全量 |
| 无效参数/版本冒用/资格范围 | W `test_invalid_config_is_rejected_by_the_package_validator`、`test_config_rejections_preserve_active_host_and_bind_version_content`；R `test_external_signed_scope_evidence_does_not_rewrite_the_package` | 03/04/07；外置报告使用 synthetic Linux scope，只验证绑定规则，不授予该平台资格 |
| 分批无关、同 checkpoint+尾日志 | W `test_same_canonical_stream_in_different_batches_has_same_ready_digest`、`test_checkpoint_restart_replays_nonempty_tail_without_authority` | 04/05；有独立三条决定与摘要比较 |
| 缺 checkpoint/缺口/schema/不兼容 Keep | W `test_missing_checkpoint_and_tail_gap_refuse_empty_restart`、`test_native_reopen_rejects_incompatible_checkpoint_schema`、`test_config_rejections_preserve_active_host_and_bind_version_content` | 05/07；不回退为空状态 |
| 预热不足/超预算 | W `test_warmup_insufficient_is_a_visible_failure`、`test_warmup_event_budget_exhaustion_is_not_ready`、`test_new_config_validate_rejects_insufficient_warmup_without_revocation` | 04/07 |
| Migrate/跳号/重复/checkpoint进度 | W config-rejections、`test_discontinuous_sequence_fails_closed`、`test_snapshot_progress_must_match_live_intent_sequence`；核心 supervisor/gateway 序列拒绝 | 04/05/07；不新增 Migrate ABI |
| 同组合第二获权实例/跨域组 | W `test_risk_warning_and_node_placement_still_reject_unbound_instance_authority` 实际拒绝额外身份获权；跨域原子组反向运行证据 **not_run** | 06/10；`TradingShard.admitDomainGroup` 的 InvalidDomainScope 检查是源码证据，未找到对应反向运行测试，不由成功的域内组推断通过 |
| callback异常/超时/输出/内存超限 | W `test_callback_hang_is_killed_by_external_budget`、`test_excessive_diagnostics_are_bounded_and_stop_the_host`、`test_callback_allocation_over_the_hard_limit_stops_the_real_host`、`test_shared_memory_failure_stops_all_members_and_leaves_other_host_ready` | 04/10；Windows Job；Linux资源未取得证据 |
| 切换后旧会话/旧激活迟到 | W `test_enable_applies_real_barrier_then_actual_package_output_reaches_native_core_and_pause_revokes`、`test_shared_members_emit_their_own_complete_groups_and_late_output_is_rejected` | 06/08/10；实际输出 frame |
| Unknown/未完成订单/周期不能承接 | W `test_live_order_blocks_cutover_and_revokes_without_clearing_history`、`test_successor_live_order_rejection_does_not_close_or_clear_the_order`、`test_rebuild_retains_sequence_cycle_deadline_and_latch_and_recovers_new_config`；cycle-recovery 五阶段回归 | 07/08；不自动平仓 |
| 同命令重试/当前版本冲突 | R `test_web_restart_retries_once_and_reports_version_and_identity_conflicts`；两条连续链的接替重试 | 03/07/08/09/11；真实 Web 与持久记录 |
| 激活后故障/回退旧代码 | W `test_successor_lost_commit_ack_stops_and_reopen_cannot_restore_predecessor`；N `test_native_lost_cutover_ack_blocks_predecessor_recovery`；连续链 ForwardRollback | 08/09；未知 ACK 禁止前任恢复 |
| 离线通过但无真实资格 | 连续 Python 链断言 qualifications=[] 且未授权；R external-scope 绑定/拒绝测试；UI self-check | 03/11；不表示经济/运行资格 |

## 持久化、中断和重试：复用前核实

ADR 0004 的 DurableStore 与原生 checkpoint Repository 仍负责持久化；安装器拥有完整
版本目录、current 发布与结果记录；InstanceManager 负责恢复进度及未知切换关闭。
本轮未新增恢复格式、发布协议、独立 CLI 或交易授权入口。

发现旧 R 整类被标为 Linux-only，即使 setUp 已选择 WindowsFilesystemApplier 也全部跳过。
本轮仅将 POSIX symlink/mode 测试保留为 Windows skip，其余测试复用实际平台安装器；
把测试中的 readlink 改为现有 `current_artifact()`，外置资格不可变字节检查读取实际版本目录。
因此 Windows 现在实际执行安装失败不改变 current、Web 重开后同命令只应用一次、丢失结果
历史禁止新发布、结果持久化失败为 unknown、首次/后续重启失败、junction 拒绝及资格绑定。
没有为已有覆盖重建故障矩阵。

既有 W `test_recovery_resolves_committed_publication_before_web_acknowledgment` 和
`test_recovery_exception_keeps_only_previously_verified_checkpoint` 验证未确认 publication；
`test_interrupted_cutover_cannot_recover_the_old_config_as_current`、Python/原生 lost-ACK
用例验证新增配置/激活接缝。它们是离线故障注入，不是实际磁盘断电或 standby ACK 资格。

## 本轮结果与原始记录

- 发布测试：[11-release-tests.log](11-release-tests.log)，15 项，14 通过、1 POSIX skip，
  [exit 0](11-release-tests-exit.txt)。
- 初始冻结连续链：[11-lifecycle-final.log](11-lifecycle-final.log)，2/2 通过，
  [exit 0](11-lifecycle-final-exit.txt)；最终预算配置的两条链由最终全量重新执行。
- 首次完整 Python 套件：[11-python-windows-full.log](11-python-windows-full.log)，343 项，
  339 通过、1 失败、3 skip，1116.353 秒，[exit 1](11-python-full-exit.txt)，不作为通过。
- 最终冻结 Python 套件：[11-python-windows-final.log](11-python-windows-final.log)，
  **343 项，340 通过、3 平台 skip，1095.045 秒，exit 0**，
  [独立退出码](11-python-final-exit.txt)；
  最终身份/包配置以该日志中的两条 CONTRACT_E2E 为准。
- UI：[11-ui-check.log](11-ui-check.log)，[exit 0](11-ui-exit.txt)。两个变更测试文件的
  Python py_compile 及全 python 目录 compileall 通过，[compileall exit 0](11-compile-exit.txt)。
- 三项 skip 分别是 OwnerSession POSIX 权限位、忽略 RLIMIT_AS 的 Linux 内核反向路径，
  以及 POSIX current symlink/mode 检查。Windows 实际生命周期/ACL 和 Job 预算由其他
  已运行用例覆盖；skip 不等于 Linux 通过。
- 最终日志保留一个 loopback socket ResourceWarning，分配来源未捕获，没有抑制。
  因此功能通过不构成长时 socket/进程寿命资格。首次全量也保留原始 warning。
- 全量结束后重新核对 268 个冻结文件全部匹配；两条最终 CONTRACT_E2E JSON 均可解析，
  Python 11 个步骤、原生 7 个步骤，四个实际签名发布的安装身份完整，最终实例均已撤权。
- 核心**复用** 10 的 [825/825 原始日志](10-core-tests.log) 与 [exit 0](10-core-exit.txt)，
  本轮没有重跑核心全量。11-freeze 重新哈希核对了确切 test.exe，SHA-256 为
  `582e837e161cfa7098eb622deef55ec818955f189afc22a95f848df9e5c88865`；
  `git diff 95c0c043 HEAD -- src build.zig` 为空，10 的 15 项源码/安装二进制身份全部匹配。
  同一核心/build 输入可复用该证据，不把 10 的 Python 全量升级为本轮结果。
  原始核心日志中的 `failed command` 字样仍保留，原进程退出码为 0。

## 中间失败与支持边界

原始失败日志不删除，均不作为通过依据：

- `11-lifecycle-initial` / `11-python-lifecycle-initial`：连续夹具更改已有 config schema
  内容却复用身份/版本，产品正确拒绝；两个定义现使用相同 schema 内容。
- `11-python-lifecycle-retry`：Keep 升高预热需求后，新 Successor 的 Rebuild 输入不足；
  `11-python-lifecycle-final` 的多批输入又违反 component batch 合同。最终链通过版本 3
  的显式 Keep 把预热参数恢复为 1，再执行 Rebuild，不修改产品校验或伪造就绪。
  `11-python-lifecycle-supported` 为该链通过记录。
- `11-native-lifecycle-retry`：已获权实例关闭后端引发既有 fault 锁存，重开可 Ready，
  但再次启用正确返回 TradingSafetyGateClosed。最终正向链在首次启用前重开，既有故障
  专项仍验证撤权；不得从该正向链推断故障锁存可自动解除。
- `11-publication-final`：将 Linux 用例移到 Windows 后，最后一个 POSIX readlink
  断言报 WinError 4390；发布拒绝断言已通过。改用公共 applier 查询后发布全量通过。
  `11-publication-initial` 是先前三个借用用例通过记录，不是最终冻结测试集合。
- 首次全量的 Python 连续链在首次创建时返回 Stopped，原因是
  `candidate callback or warmup budget exhausted`，已到 cursor/barrier 28，具体延迟来源
  未捕获。其余 339 项通过，3 项 skip；同一初始冻结的
  [独立复跑](11-python-failure-isolated.log)通过，[exit 0](11-python-failure-isolated-exit.txt)。
  `906b8d8f` 仅把连续链签名夹具配置为 5 秒回调、30 秒预热、45 秒 HTTP；
  原产品时限校验和专门的超时反向测试不变。此链不作为 1 秒回调或性能资格证明。

## 审查与结论

独立 Standards / Spec 双轴审查及预算调整复审均为 0 项可操作发现，原报告见
[11-review.md](11-review.md)。审查不执行测试；最终完整套件和身份复核已完成。
11 resolved，仅表示冻结版本的证据收口完成；地图在必需实现/验收仍有缺口时保持 open。

跨域原子组反向运行证据、Linux singleton 的实际 RLIMIT_AS 资源验收及共享 Host 总预算实现仍缺失；Windows 结果
不代替 Linux。原生观察策略完整日志重建、共享 Host 最多 16 成员及既有有界历史仍是范围
限制。实际 Venue、Demo/Testnet、节点进程重启/断电/热备耐久、常驻部署、soak、经济与
production qualification 均为本轮 not_run；未访问凭证、发真实交易或执行生产部署。
