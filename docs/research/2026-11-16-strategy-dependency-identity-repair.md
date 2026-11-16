# 策略依赖身份与包目录迁移修复

日期：2026-11-16。实施基线：`242af6f8`。全程未使用子代理。

## 根因与业务影响

`7f21022b` 将策略移入 `strategies.cross_venue`，扫描计算移入 `opportunity_scanner`，但 V2 依赖摘要将 dataclass 的完整 `__module__` 作为类型身份。业务字段未变，导入路径变化仍改变 SHA256。单项冻结合同检查在该提交父提交通过、该提交失败；诊断进程仅恢复旧模块名即可使两种模式全部 12 个依赖摘要重新匹配原合同。

问题同时影响实际 `restore()` 的依赖校验、Cycle 持久保存的 `last_facts_digest` 和同游标事实去重。只改测试预期会掩盖旧 checkpoint 无法恢复的问题；只切回旧摘要算法，又会拒绝迁移后已经写出的 checkpoint，或在恢复后把重复事实误判为内容冲突。

## 修复合同

- `content()` 对明确列举的本项目迁移模块使用原 V2 类型命名空间，继续完整绑定类型名、字段名、字段顺序和字段值。不同完整命名空间的同名类型不会被通用截断合并。
- `matches_content()` 只读兼容原 V2 编码及包迁移期间实际写出的 V2 编码。`restore()` 仍逐项比较当前模板的完整依赖，并保留 schema、metadata、组件类型、业务进度和容量校验；真实配置变化继续拒绝。
- Cycle 同游标去重采用相同兼容校验，保留原事实摘要和修复预算。新游标使用规范摘要；重复事实不推进游标、不增加 repair 次数、不生成新意图，冲突事实仍拒绝。
- 新 checkpoint 的依赖摘要写回原稳定 V2 身份。Keep 仍保留原容器；本修复不修改经济状态、配置或权限，也不放宽 StateMigration 的业务条件。
- 未修改 `cross_venue_acceptance_contract.json`、原 `strategy_cycle_recovery_v2.json`、原 `strategy_maker_recovery_v2.json` 或其他冻结验收向量。

映射中的类型命名空间属于 V2 合同。后续移动模块时须维护显式映射并继续通过这两份历史运行中 checkpoint；不能通过重写冻结摘要默许身份变化。

## 验证入口与证据

两份运行中修复阶段的 checkpoint 保存在 `src/testing/fixtures/strategy_cycle_package_move_v2.json`，分别由 `7f21022b^`、`7f21022b` 的原始源码生成，完整提交身份记录在各行 `source_commit`。生成时实际启动 Cycle、应用 10／6 的部分成交事实并产生一次 repair；没有用修复后的代码反算期望摘要。

新增回归通过 `restore()`、`checkpoint()`、`Cycle.apply()` 验证两个历史布局的恢复、重复事实、冲突事实、真实依赖变化及新游标续跑；原冻结 IOC／maker 初始状态经实际恢复后可逐字节重存。

日志位于 `.scratch/build/scanner-06-review/`：

| 检查 | 结果 |
|---|---|
| Host／checkpoint 定向 Python | `python -m unittest -v test_arbitrage_checkpoint test_strategy_cycle_recovery`：28 项通过，22.180 秒；`fix-dependency-checkpoints.log`。含真实 Python Host 检查。 |
| 套利模块 Python | `python -m unittest discover -s python -p 'test_arbitrage*.py' -v`：229 项通过，205.476 秒；`fix-dependency-arbitrage.log`。 |
| Zig／Python／TradingShard 恢复验收 | `python tools/zig-entry.py run src/testing/integration/strategy_host_recovery_integration.zig -O ReleaseSafe --stack 536870912` 退出 0；`fix-dependency-native-integration.log`。覆盖公共盘口完整组、各周期阶段、Keep／Migrate／Rebuild、停机、亏损及风险退出、maker cancel-fill／Unknown 对冲；连续运行与恢复结果一致，旧会话被隔离，恢复前意图为 0。 |
| Python 全量 | `python -u -m unittest discover -s python -v`：434 项，431 通过、3 跳过，无失败，1396.555 秒；`fix-dependency-full-python.log`。原冻结依赖检查及两个历史布局的恢复回归均通过。 |

三项跳过仍为 Windows 不适用的 POSIX 认证文件权限、POSIX 签名包发布链接和不支持 RLIMIT_AS 的 Linux 内核拒绝加载检查；原 skip 条件未修改。Python 编译与 CRLF 感知的 Git 差异检查通过。

独立子代理审查未执行。Standards 自查按 AGENTS、领域文档及目录归属核对，未发现确定的新违例。Spec 自查覆盖 `content()` 全部调用点、实际恢复、两个历史编码和重复事实路径；版本、metadata、组件类型、依赖内容及业务进度校验保留。POSIX 权限、POSIX 发布链接及不支持 RLIMIT_AS 的 Linux 内核三项检查仍需对应环境，不通过修改 skip 条件声称验证。06 保持 open；不构成在线行情、经济、运行或生产资格。
