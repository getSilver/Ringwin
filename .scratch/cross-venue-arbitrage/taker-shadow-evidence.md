# 14 双 IOC 只读影子：离线工具实施证据

日期：2026-10-28。票据：[14](issues/14-taker-shadow.md)。实施前固定点：`8d7922d23bb52005810fd9b0ff290d3381b0ed7c`，分支 `spread-arbitrage-strategy-python`。

## 已实现范围

`python/arbitrage_shadow.py` 提供离线公开API `Protocol/Frame/Session/replay`。不接网络、不启动Host、不部署；没有sender、资金预留回调、Intent编码或交易周期对象。输入只接受现有规范Observation/depth、Option/Plan、Approval、Facts以及Signal网格和Monitor窗口事实。规则、模型、参数、研究场景继续由现有组件验证，不新增另一套权威账本或Host。

`Session`复制初始Signal/Monitor，且先通过现有v2 checkpoint验证。每帧真实调用`scanner.scan`、`Admission.propose`和`Monitor.update`，只输出候选、白名单拒绝及不可发送的建议摘要。Admission批次被丢弃，无任何core调用；影子私有Signal保留失效、评估次数及期限，只清除本帧假设建议的pending标记，不伪造reserved/rejected核心回复。外部传入状态不变。行情不健康或监测不合格时清除未消费机会；重新批准不复活缓存信号，须新网格重置/触发。

重启帧用现有`arbitrage_checkpoint.checkpoint/restore`与Host codec真正恢复Signal/Monitor；失效锁存及次数/期限不重置。它不证明真实Host子进程、日志尾、激活屏障或持久核心状态已经集成。

## 捕获、重放及显式门槛

- 捕获固定schema JSON，包括每帧完整规范depth bytes的hex、连续性、全部Frame输入指纹、cursor/时间、候选/建议/拒绝、监测动作、私有状态摘要、版本、新鲜度及本机计算耗时。整体有字节及帧数上限，满时锁存失败并明确抛错，不截断后宣称通过。
- **JSON不是单独可重放的原始输入归档。** 为避免新造通用Plan/Scenario序列化框架，调用方须另行保存完整原始不可变`Frame`序列及冻结依赖。`replay(capture_json, original_frames, session_factory)`校验每帧输入hash，再新建Session真实重算scan/propose/monitor/checkpoint，核对完整决定、状态和捕获元信息；首个分歧返回`input:N`、`decision:N`或`capture:N`。本机耗时仅作实际运行诊断，不参与确定决定比较。捕获不承担生产权威日志、防篡改签名或独立存储系统职责。
- `Protocol`无交易默认值；必须显式给出版本、代码hash、校准引用、最小帧数/时长/每帧Option负载、最大计算耗时/新鲜度/缺口帧数及帧数/字节上限。运行结果报告计算耗时、双腿/各输入新鲜度、缺口、版本变化、重启、监测动作及失败原因。Scanner/Admission仍执行既有数量/场景容量检查。
- `operational_gates_met`只表示本次离线输入是否满足所给门槛。所有报告固定`qualification=false`、`evidence=offline_unqualified`、`real_host=not_run`、`real_market=not_run`。本轮测试中的`synthetic-v1`、`a*64`及`pending-12`均为显式合成输入，不是冻结合格配置。
- 不产生模拟成交、实际收益或净值账本；建议的plan/target金额来自既有假设场景评估，不能当作实际成交/实际利润。影子不授予真实执行或盈利资格。

最小使用路径见`python/test_arbitrage_shadow.py`的`fixture`和公开测试：构造已认证冻结依赖及Frame，逐帧调用`step`，保存`capture_json()`及原始Frame归档，再以新Session工厂调用`replay`，用`report()`读取未授资格的诊断。

## 实际验证

工作目录 `D:\github\Ringwin\python`：

```powershell
python -m unittest test_arbitrage_shadow -v
python -m py_compile arbitrage_shadow.py test_arbitrage_shadow.py
python -m unittest discover -s python -p 'test_*.py'  # 此命令在仓库根目录执行
git diff --cached --check
```

公开10/10通过，语法检查通过。覆盖真实8000000 atoms建议与显式白名单拒绝、外部Signal不变、篡改输入/决定及数值类型定位、实际checkpoint重启及InvalidLatched、缺口/版本/负载/新鲜度、满容量锁存、错误不隐藏、撤销批准不得复活旧信号、新网格重置/触发、编码负载计入计算预算及合成门槛通过仍不授资格。

Python全量221/221通过，暂存diff空白检查通过。自审额外补充坏输入不得伪造模型InvalidLatched或controlled_exit及JSON数字类型不得宽松比较的失败回归；修复后均通过。

固定点两轴审查：Standards无可操作发现，类型敏感比较补审也通过。Spec初审1项P2：计时早于累计捕获JSON编码，可能低报完整step计算负载；已把完整编码/字节检查及返回值复制纳入计时，容量计算统一为所有耗时字段预留最长u64以避免机器速度改变紧边界容量结果。可控平台时钟/JSON编码代价的公开回归先红后绿，Spec补审无剩余发现。两轴均未把本地合成证据当作真实资格。

## 未运行及剩余责任

真实冻结合格参数依赖[12](issues/12-taker-calibration.md)，目前无真实研究输入。真实规范市场数据、Host输入/持久捕获、生产平台时钟及延迟、预登记真实时长/独立样本/负载、版本切换/重启及实际连续流影子均**not_run**。完整Frame归档存储与认证仍属于实际接入，不以测试夹具的本地对象替代生产捕获证据。

数学、离线公共组件行为、经济资格、运行资格分别留证：本次只完成离线工具及合成组件行为回归；12经济资格pending、14运行资格pending，票据保持in_progress，真实完成条件不勾选；[独立集成验收](integration-acceptance.md)继续pending。未认领15，未执行任何真实/Demo订单，后续交易需另行有界授权。
