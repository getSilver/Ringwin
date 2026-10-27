# 07 Python 只读机会扫描证据

日期：2026-10-28；分支 `spread-arbitrage-strategy-python`。
开工基点 `8707980e2b6572de5840540707c6730d36ce86be`，本次改动未提交。
用户明确授权完成07；文档中的旧授权范围已按本次请求更新。

## 实现和输入

- [扫描模块](../../python/arbitrage_scanner.py)：`Observation`、`Plan`、`candidate_id`、`scan`、`display_json`。
- [公开测试](../../python/test_arbitrage_scanner.py)：11项，复用前置票规范深度、模型、场景和校准夹具。
- [现有验收入口](../../python/verify_strategy_host.py)增加扫描测试；未运行该入口中的Zig全套。

依根级GLOSSARY、ADR0001/0007/0012及本模块策略、参数、集成验收合同工作。
当前已有704字节规范深度codec与06公开 `evaluate`，本次直接复用。
不改Host framing、核心事件schema、经济公式、预测算法或权威归属。

观察范围由调用方提供规范 `Observation`：Venue、ExchangeAccount、InstrumentRules、
产品类型、规范盘口bytes及连续性事实。不是Venue私有事件，也不读取凭证。
按稳定身份排序，发现不同Venue/账户、同基础/报价资产的配对；
永续/永续两个方向，现货/永续仅允许现货多头，现货/现货仅观察。
每方向展示双IOC、A maker/B taker、B maker/A taker三种独立证据槽。
未提供研究计划时仍显示 `missing_evidence`，不会虚构预测。

`Plan`注入冻结联合预测场景、06政策、Estimator、Calibration、SimulationError、
计算限制、有效期及预估占用资金。场景生成/研究数据供给由调用方负责；
本票不自动训练、选择或启用模型。模型可以继续使用前置票冻结AR1口径。
`candidate_id(pair, direction, mode, maker_leg)`同时作为政策scope，
从而将06概率校准绑定到确切配对/方向/maker腿，不能跨槽复用。
校准/模型/场景内容仍由06自身绑定及验证。
场景两腿账户、规则、产品必须与观察一致；同刻首帧必须等于实际规范输入。
未来场景是显式假设，不是已发生的行情事实。

扫描与交易评估直接调用同一个 `arbitrage_evaluation.evaluate`；
候选输出参考收益、固定目标、实际计划收益、概率下界、最差路径净值和未闭合权重，
附数据截止点、cursor、模型hash、政策/校准版本及场景/估计器摘要。
同配对/方向/模式/maker腿有多个数量时，优先通过全部评估者，
再按计划收益最大、占用最少、数量最小确定性选择；完全重复数量输入拒绝。
跨模式按计划收益、占用和稳定身份推荐；这不是08的跨配对资金分配或预留。
所有数量/身份/货币/时间在展示JSON中用字符串或精确分数对，避免浏览器整数精度丢失。

`status=evaluated`只表示本次注入证据通过离线评估。
**所有行始终 `trading_qualified=false`**；推荐不授予白名单、统计资格或运行资格。
扫描接口没有白名单、OrderIntent、预留或执行能力，资金占用值只是假设输入。

## 刷新和展示合同

`scan`返回完整替换快照：`schema=arbitrage_candidates_v1`、`replacement=true`、
扫描时刻、cursor、候选列表。消费方必须替换旧集合，不得将缺失候选继续视为有效。
每次新评估要求政策时刻等于扫描时刻；只带旧政策刷新显示 `evaluation_cutoff`，
不把旧计算包装为当前评估。08须独立重评，不补发过期信号。
缺口、不连续、过期规则、陈旧或两腿时间偏差使候选降为pending并带原因。
未来盘口、身份/规则/资产错配、重复输入、超容量属于非法输入，抛 `Rejected/ValueError`，
调用方不得保留上一轮推荐冒充本轮成功。

候选有效期取显式期限、预测/风险期限、数据年龄、规则和入场校准期限的最早值。
`display_json(snapshot, at_ns=...)`在无新行情时也检查过期，撤销推荐且不修改原快照；
时钟倒退或未知schema拒绝。它是扫描快照的本地展示编码器，不是网络反序列化器。
观察输入最多64、计划最多256、配对/输出最多256，超限显式失败，
不会静默截断；单次经济评估继续使用06现有有界工作预算。

当前分支没有 `control_plane_web.py`。已只读核对另一工作树
`D:/github/Ringwin-control-plane/python/control_plane_web.py`：
`projection()`经OwnerSession授权消费 `projection_provider.views()`；
`do_GET`已有 `/api/projection`，返回 `ok/shards`，未有候选路由/schema。
另核对 `control_projection.py` 和 `src/control_projection_probe.zig`：
既有读模型经核心SemanticReplay投影，不应把策略候选伪造为核心journal事实。
本票测试 **规范输入→候选→展示JSON→过期/缺口响应**，没有宣称浏览器端到端通过。
真实Web应沿现有授权与只读provider模式承接候选，并定义Host外候选传输、
会话/版本及刷新失败撤销语义；不得另建控制面或把候选塞入交易输出frame。
该未实现接线继续列在[独立集成验收](integration-acceptance.md)，不阻塞本票策略侧关闭。

## 实际命令及结果

在仓库根目录执行：

```powershell
python python/test_arbitrage_scanner.py
python -m unittest discover -s python -p 'test_*.py'
python -m py_compile python/arbitrage_scanner.py python/test_arbitrage_scanner.py python/verify_strategy_host.py
git diff --check
```

最终结果：扫描 **11/11**；Python全量 **116/116**；语法编译及diff检查通过。
公开测试覆盖共享评估一致、白名单外发现、缺证据、顺序无关重放、稳定身份、
完整替换、TTL边界、无行情到期、数据缺口/陈旧/偏差、规则过期、现货范围、
跨资产过滤、重复/未来/错配拒绝、三模式与maker腿区分、独立穷举数量选择、容量和展示错误响应。

复现展示样例（测试驱动器，不是市场数据）：

```powershell
@'
import sys, hashlib, json
sys.path.insert(0, 'python')
from test_arbitrage_scanner import fixture, scan, selected
from arbitrage_scanner import display_json
observations, plan = fixture()
snapshot = scan(observations, (plan,))
print(json.dumps(selected(snapshot), sort_keys=True))
print('display_sha256=' + hashlib.sha256(display_json(snapshot, at_ns=10000).encode('ascii')).hexdigest())
'@ | python -
```

输入：Venue10/账户1/Instrument1与Venue11/账户2/Instrument2，
基础Asset2/报价Asset1，方向+1、双IOC、基础数量1、政策/校准版本1；
时刻10000、cursor7、有效期10050，人工独立块校准夹具和冻结联合支持。
该数据只验证合同行为，不具有真实市场统计独立性证明。

- 模型hash：`698e9ea0cc474a52258c059427d675ac3a62d2d9d68180117e1788855294d0e9`。
- 候选身份：`b73173889d697ff714cbdda80daea5993ce3001832861577dbcfbcc459b6fe5b`。
- 场景摘要：`c821bf88414eaa4b1a32227cd7d858ef157d7b23c0506997ff43614923e2a646`。
- 估计器摘要：`81a0034095ccbd9d3a077aadf1eea5b54434bf8afb49aeb4884ba242952464c4`。
- 参考收益10000000、目标8000000、计划收益8000000 atoms；概率下界680000 ppm；
  最差路径8000000 atoms、未闭合权重0；推荐true、交易资格false。
- 全展示JSON SHA256：`698ee4fbd82567fff5ced3a1195de5bfe6ef6af52f617c0747b060f201f72cd2`。

自查补齐maker腿的政策scope绑定、展示TTL受校准期限限制及容量测试；
未启动独立复核代理。没有修改其他工作树。
未执行Zig全套、mypy、真实Host候选传输、Web路由/浏览器、实际Venue、
市场校准、影子、Demo或真实交易；未部署、未同步GitHub。
公式一致性已验证；统计有效性和运行资格均未授予，按12–15及集成清单独立验收。

## 2026-10-28 依赖补提交核对

用户明确要求补交07，使当前分支包含08的完整依赖；不重写已有08提交历史。
重新核对本票完成条件、扫描器完整源码/公开测试、08的导入和共享评估调用，
以及验收入口、map、集成清单和原有证据。扫描器不获得白名单或交易权限。
本次不修改扫描算法；提交07的源码、测试、验收入口和tracker/证据，
并在08证据中说明其未提交依赖已补齐。

实际重新运行 `python python/test_arbitrage_scanner.py`：11/11通过。
为避免测试误用工作区未跟踪文件，另外从暂存Git tree仅导出`python/`，
在独立的`.scratch/build/ticket07-verification-*`目录运行Python全量回归及语法编译；
该目录不包含原工作区未跟踪文件或缓存。实际导出tree为
`af772fd55b22abad4df54dadd0d0e8a29131c64f`，目录为
`.scratch/build/ticket07-verification-0bbf1621`。
执行 `python -m unittest discover -s python -p 'test_*.py'`：133/133通过；
`python -m compileall -q python`、文档相对链接及暂存diff检查通过。
该tree之后仅补充此验证记录，Python源码不变；07/08运行和测试依赖均来自Git tree。
未重跑Zig/Host全套或真实Web/Venue集成，未部署、交易或推送。
