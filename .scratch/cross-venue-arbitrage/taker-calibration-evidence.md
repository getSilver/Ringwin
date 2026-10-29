# 12 双 IOC：开发阶段离线研究工具与资格缺口

日期：2026-10-28。分支 `spread-arbitrage-strategy-python`；实施前HEAD/审查固定点 `e56fac43f4c28bab7ae55f543f19bf844cd00f63`。用户明确目前无真实数据/市场，授权完成能开发的离线范围。本记录不构成已完成的真实研究。

## 实现范围与使用

`python/arbitrage_research.py`：

- `Protocol`冻结四段半开时间区间、最大标签/完整周期评价跨度、预登记候选配置内容哈希、最大尝试、收益/回撤/尾损约束、块/周期下限、覆盖目标、数据/代码摘要、解释器/依赖引用及seed。分区为全部配对共用UTC时间边界，间隔不得小于最大评价跨度。候选哈希应绑定03–11已有模型、期限、目标、经济/执行配置；本工具不提供另一个预测模型或撮合器。
- `partition`剔除跨界、超跨度、未成熟和观察时间落入下一分区的标签；`label_partition`直接接受现有 `arbitrage_baseline.LabelTracker` 输出。完整周期报告的跨入/跨出分区及未闭合尾部均保留并拒绝，不能随标签过滤而丢掉风险。
- `summarize`从当前公开组件产生、调用方已归属的周期结果与NAV/累计外部净分配投影计算完整流量调整曲线、收益、回撤、最差周期损失、拒绝/停机/未闭合计数。全量输入保留，金额是同一报价资产原子整数。费用、资金费、残余及未闭合风险估值应已经进入来源NAV，不另造账本或把预留当费用。
- 实际计划误差与参考政策误差分开；无参考政策真实结果则参考误差为None。阶段频率、均值高估与占用分位数只是诊断，不是经块相关性校准的保守下界/上界；缺失结果不填零。`declared_blocks`只是输入声明的不同块引用数量，不证明有效独立样本。`economic_qualified`始终False；即使调用方声明historical，仍记录 `external_qualification_required`。
- `Study.create(path)`显式创建独占研究journal；之后 `Study(protocol,path).validate(candidate, equity=..., cycles=...)`登记并消费尝试，再算选择验证报告。`freeze()`在预登记风险内按完整流量调整净收益选择最高候选，哈希确定性破并列；不是参数优化器，候选预测/模拟仍调用既有公开组件。全不合格时拒绝。
- `holdout(...)`必须已冻结，先持久消费区间再计算报告；失败/中断不能重用原保留区间。同一journal跨研究版本和代码/数据哈希、进程重启拒绝任意重叠已见测试区间，以及任何已登记协议的训练/校准/验证区间，防止改名为“未见测试”。新研究须冻结新版本并使用全新未见保留区间。独占lock、临时文件、fsync与替换保护本地写入；提交前再次核对条目/序列化容量，超限不改旧journal；残留锁/临时文件失败关闭。须保留同一journal；删除、改写或换路径使“未见数据”声明失效，工具不提供外部权限/防篡改服务。

影响范围仅新工具、新公开测试、本票、map和本证据；不修改现有策略、Host、核心、Fixture、配置、导出或依赖。没有自动接线、部署、网络请求、真实/Demo交易或GitHub写入。未跟踪 `.scratch/zig-incremental-research.md` 保留且不提交。

## 数据源核查

普通 `rg --files`只见两份测试JSON，不能据此认定隐藏研究数据不存在。随后使用 `rg --files --hidden`、`git status --short --ignored`，再用Python `os.walk`核查包含ignored文件的研究扩展名，排除`.git`、`.zig-cache`、`zig-out`、`__pycache__`、`.scratch/build`。仅检查路径/必要非敏感样本，未读取`.env.local`值、未访问仓库外账户或存储。

扩展名`.csv/.jsonl/.ndjson/.parquet/.db/.log/.bin/.json`共1622文件：`.scratch/core-continuous-capacity`1579、`.scratch/archive`24、`.scratch/credential-security-closure`14、`src/testing`2，其余为Demo政策、安全审计和VSCode设置各1。没有发现本策略模块捕获或真实历史研究数据清单；这不是对未知外部数据仓库或任意扩展名二进制的全盘认证。

抽核`core-continuous-capacity/11-final-v3-app-evidence/workload.json`的固定seed/owner场景、`samples.jsonl`的进程容量指标；它们是合成容量/故障证据。ignored的`archive/windows-process-chain-verification/run-2026-10-03-9600`含manifest/snapshot与旧资格地图；其他命名候选为旧OKX Demo报告/政策。这些不是包含双腿接收时序、联合深度/延迟、实际费用资金费与闭合周期的真实经济研究输入，Demo不替代真实收益证据。没有将这些产物、单元夹具或重复模拟次数计为有效市场样本。

## 验证与剩余边界

- Python `3.9.18`；新工具仅标准库与既有Python模块。`python -m pip show mypy pyright`：均未安装；仓库未配置Python静态类型检查器，`compileall`只证明语法，不冒充typecheck。
- TDD首个分区测试因模块不存在失败后通过；报告与journal切片分别先因公开接口不存在失败后实现通过。测试数据全部明确合成，成熟标签使用真实 `AR1.predict`→`LabelTracker.advance` 公开路径。
- `python -m unittest discover -s python -p test_arbitrage_research.py`：最终10/10通过，0.411s；两轴各自独立10/10通过。
- `python -m unittest discover -s python -p test_arbitrage_probability.py`：5/5通过，0.132s；`python -m unittest discover -s python -p test_arbitrage_cycle.py`：21/21通过，0.330s。
- `python -m unittest discover -s python -p 'test_*.py'`：最终202/202通过，20.829s。仅为开发回归，不是实际保留研究。
- `python -m compileall -q python`、`git diff --check`：通过。
- 两轴审查：Standards初审1项P2（提交后journal容量不可读）已由先失败的容量保持回归修复，补审无剩余发现。Spec初审时间区间改名泄漏与自查同时定位；新增回归先失败后修复，且跨入周期完整保留，最终Spec无剩余发现。审查基点为上述实施前HEAD，最终工作树源码未再修改。
- 最终源码SHA256：`arbitrage_research.py` = `4918F42085693B70B9E12BCE5DA8A717E5143CC93C8D1CF7F302EF128B871F78`；`test_arbitrage_research.py` = `DA8ABE90769057C4A44BC8A56ADEC1AFDA8E4A759A6EF08E0C1A764D0D2059B6`。

数据核查的实际可复跑命令（PowerShell；输出1622及上述分组）：

```powershell
@'
import os
from collections import Counter
extensions = {'.csv', '.jsonl', '.ndjson', '.parquet', '.db', '.log', '.bin', '.json'}
counts = Counter()
for root, directories, files in os.walk('.'):
    directories[:] = [d for d in directories if d not in {'.git', '.zig-cache', 'zig-out', '__pycache__'} and os.path.normpath(os.path.join(root, d)) != os.path.join('.scratch', 'build')]
    for name in files:
        if os.path.splitext(name)[1].lower() in extensions:
            relative = os.path.normpath(os.path.join(root, name))
            counts[os.path.join(*relative.split(os.sep)[:2])] += 1
print(sum(counts.values()))
for name, count in counts.most_common():
    print(count, name)
'@ | python -
```

尚未执行：真实数据预登记与冻结、基线/挑战模型×期限×目标的完整策略事件级比较、选择后保守误差/阶段概率与占用时间的块相关性/删失校准、真实完整资金曲线和一次性保留研究。现在的工具不会把诊断量自动生成合格参数包；不存在可供14使用的合格冻结参数。12保持in_progress、真实经济资格pending；14真实影子验收仍阻塞。公式/离线行为、统计有效与运行资格分别验收。
