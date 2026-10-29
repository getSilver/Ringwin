# 11 Maker–Taker 策略侧实现与离线证据

日期：2026-10-28。分支 `spread-arbitrage-strategy-python`，固定审查基点为10最终提交 `9dabde0c760a39ad0329ff885816645c259cce8d`。

## 范围与调用方合同

- `python/arbitrage_maker.py` 提供 `Plan`、`Quote`、`Stress`、`select_quote`、`Cycle.from_admission/start/apply/exposure_bounds` 以及独立的 `queue_baseline`。沿用08准入身份、06联合完整周期评估和09的已认证事实验证、固定Holding目标、双门槛、风险锁存及受保护IOC退出。
- 所有输出都是建议。核心仍拥有OMS、订单身份、共同准入、预留、资金、账本、原周期独占及经济事实。调用方必须认证原周期完整 `Facts`，包括归档唯一已应用Fill累计、净经济持仓、费用更正、报告/成交覆盖和当前权限；不能以OMS累计量代替经济增量。
- `Quote.market` 绑定当前深度及费用输入。报价使用预登记 `best_bid-k` / `best_ask+k` 有界集合、原价格边界、完整原对冲目标的可证明深度、完整周期费用/资金费/修复与失败联合经济场景及06双门槛。场景、费率、时钟、概率与压力界必须由调用方按已认证执行配置/研究产物生成，Python不从标签名字推导实证资格。
- 换价 `Quote.economic_ref` 必须匹配当前经济投影；`applied_trades` 的两腿已应用量必须匹配当前事实。各场景保留同一历史成交前缀的原价格及费用，只给其后新增maker数量使用候选价格，不得重写历史成本。修复/退出已实现贡献仍由核心认证投影及场景完整承接。
- 原生Post-only复用现有 `strategy_host.output_frame` 的专用order type `2` / TIF `3`。普通GTC不替代。`native_post_only` 是调用方认证能力证据，不是Python自行授予Venue资格。
- `Action.cancels` 返回原maker意图序号，反复建议保持原身份，不表示取消成功。当前Python Host order codec没有取消入口；混合取消/对冲的 `Action.encode` 明确拒绝整体编码，调用方必须用原订单关联接入核心取消API，并显式处理IOC建议，不能悄悄丢掉取消。真实取消请求、授权/包络、接收响应与发送顺序仍属I-Maker集成。

## 执行与恢复不变量

每腿至多一张活跃maker入场单；旧单终态且经济覆盖、全部maker历史及在途hedge核对完成后，才允许按剩余量换单。改价间隔、累计次数、最初报价时刻、总寿命、修复/退出次数和期限不因换价/重启重置。模型Warning、风险、撤权、对冲深度丢失、尾差期限、风险数量上限或hedge预算阻塞会立即建议取消，不等待普通改价间隔。

逐笔增量使用 `net_maker_position - net_hedge_position - possible_pending_hedge_base`，不足最小量继续有界积累。缺回报的已提出hedge按全量可能成交计；终态但经济覆盖未完成时也保留尚未经济应用的可能量。Unknown只查询原身份并撤maker，不换身份重发；迟到/重复Fill和核心归档投影不额外制造增量。无法合法对冲时停止maker新增风险。费用更正导致超额对冲时修剪hedge，不把maker模式偷偷改成IOC追单。

`exposure_bounds` 独立输出有符号maker减hedge的可能净敞口。Unknown使用调用方认证区间；普通sent/缺回报/经济未覆盖订单则按每腿可能增加或减少数量构成区间，减仓单也计入。例如10/10匹配后两腿各10手独立退出，净敞口区间为 `[-10,10]`，不能报告 `[0,0]`。

v2新增严格 `maker_cycle` component tag，保留已有IOC的 `cycle` tag及原v2意图编码。实际保存原/替代/hedge/退出意图、Post-only类型、当前maker身份、报价最初/最近时刻、累计换价/对冲/退出次数、取消/替换进度、尾差起点、经济输入摘要、退出锁存和已冻结目标。恢复校验类型、预算、身份、时间和依赖；未知字段/状态或错误版本失败关闭。旧版本不认识新tag时不得猜测恢复。

## 队列、联合收益及压力

队列基线独立于经济及敞口计算。到达时全部可见同价数量置于前方；只有具有认证tape引用、身份唯一的主动成交才消耗前方量。未知撤单不被视为发生在前方。研究压力独立改变隐藏前方量或撤单位置；不能将L2估计当成真实排队或实际Fill。

算例：前方10、自己3，未知撤单5后主动成交7，baseline为ahead=3、估计filled=0；额外隐藏4时ahead=7、filled=0；只有显式前方撤单压力假设才得到ahead=0、filled=2。重复事件/重复tape引用及缺认证的主动量拒绝。

报价须带完整压力集合：零成交、部分成后取消、hedge失败、撤中成交、Unknown、隐藏量、撤单位置和不利选择；每项显式记录损失及敞口区间，并与固定损失/敞口预算比较。这些是预登记压力界，不冒充经验概率。真实联合场景权重另由06校验和为1；未解决Unknown导致拒绝，不能当成零损失。独立算例：90%完整净收益80m、10%失败修复净损失20m，联合期望70m，而不是忽略失败损失的72m；固定目标仍80m。

## 实际验证

环境：Windows PowerShell，Python 3.9.18。输入为仓库内确定性规则/深度codec及人工认证投影夹具，无网络交易或Venue会话。

- TDD：首个native Post-only用例先因模块不存在失败；逐笔增量用例先返回无hedge失败；Unknown恢复先因未注册真实component失败；终态hedge经济未覆盖回归先重复对冲失败；超额hedge修复先错误请求makerIOC失败；Spec发现的退出敞口回归先得到 `[0,0]` 失败，随后逐项修复通过。
- `python -m unittest discover -s python -p test_arbitrage_maker.py`：20项通过，exit 0。
- `python -m unittest discover -s python -p 'test_*.py'`：最终192项通过，21.847s，exit 0；覆盖至代码提交 `0965de85`。此前首版189项通过，18.412s，exit 0。
- 父代理独立复验同一全量命令：192项通过，22.166s，tests_exit 0；独立compileall退出0。父代理同时核对09/10/11 resolved、12/13未认领、14/15依赖及真实集成pending。换行修正仅格式变化，未重复执行逻辑测试。
- `python -m compileall -q python`：exit 0，仅语法/字节码编译验证；仓库没有独立类型检查配置，不称typecheck。
- 实现阶段 `git diff --check` 的工作树检查为exit 0；该检查不覆盖已提交内容。父代理最终范围审计 `git diff --check 4d6f5be2..HEAD` 发现新增 `test_arbitrage_maker.py` 的338行CRLF在提交blob中被判为尾随空白。随后只将该文件换行为LF，断言其余字节完全相同，不改逻辑或Git whitespace配置；最终提交后对完整09–11范围重新执行同一命令，exit 0。其余授权范围文件没有同类告警。
- `python/verify_strategy_host.py` 已加入09 Cycle、10 checkpoint和11 Maker三测试入口；未运行其整套Zig/产品链，也未执行无关Zig全套。

20项Maker测试覆盖两种maker腿、native wire、唯一增量/缺回报/经济未覆盖、撤中Fill、Unknown与原身份恢复、取消终态及经济覆盖、部分成交换价原成本前缀/剩余量、次数/间隔/总寿命、深度丢失、尾差最小量/期限、数量/预算边界、队列独立压力、联合失败损失、模式保持、固定Holding目标/TP/退出Unknown/闭合全阶段checkpoint及损坏状态拒绝。

## 双轴审查与资格边界

Standards与Spec独立子代理并行审查，固定范围 `git diff 9dabde0c760a39ad0329ff885816645c259cce8d...HEAD`。实现提交为 `8b13ac1b`、`58d90a40`、`0965de85`。初次Standards覆盖至 `58d90a40`，无发现。初次Spec发现1项P2：在途减仓没有计入净敞口区间，已在 `0965de85` 修复并增加公开失败回归。两轴最终均确认完整基点至 `0965de85` 无剩余已确认发现；Spec代理独立运行20项Maker测试通过。文档终结提交随后单独记录，不改上述代码范围。

公式/状态与离线回放正确性是本票交付范围。概率校准夹具是人工构造，不证明有效独立市场样本、样本外净收益、队列成交率、不利选择或经济有效性；12/13经济资格仍未执行。实际Host/核心/Venue公共路径、原身份取消、当前激活包络、无权日志尾重放、真实Fill/预留/账本与经济闭合、跨平台数值一致及14/15运行资格均pending。未部署、未进行真实/Demo交易、未同步GitHub，也未认领12以后。
