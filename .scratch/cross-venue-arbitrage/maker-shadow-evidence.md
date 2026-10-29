# 15 Maker–Taker 只读影子工具证据

日期：2026-10-28；分支：spread-arbitrage-strategy-python；实施基线：7237456d6777c8e9dcd54d88752f74eafb3adccf。

用户明确当前无真实数据与市场，授权将可开发部分完成；不授权部署、真实/Demo交易或GitHub写入。

## 开发交付

`python/arbitrage_maker_shadow.py` 的 `Frame` / `Session.step` / `capture_json` / `report`，重放复用 `arbitrage_shadow.replay`。14驱动仅增加模式/schema、初始化身份、组件扩展及恢复metadata接缝，共用原捕获边界、计时及报告。未添加另一套撮合、预留或账本。

- scanner候选、Admission/Signal白名单重评及Monitor仍走现有真实公开组件。Maker候选与捕获schema独立；初始Maker计划/进度纳入capture依赖身份。
- Session深拷贝调用方Cycle/Signal/Monitor；idle周期须真实Admission推荐与完整from_admission绑定，随后运行select_quote/原生Post-only建议。活动周期基于调用方认证Facts进行撤换/增量hedge/Unknown处理，正常替换等旧单终态经济覆盖；Cycle market必须精确匹配同帧规范Observation的规则/盘口，核心停开仓/config有效期同时约束建议；白名单、版本、缺口、时效、健康失败阻止扩大敞口并给安全撤单建议。
- 只输出dict/list标量建议；不返回Action/Intent或encode接口，没有发送器、资金/预留接口或外部写入。Cycle仅为影子私有副本，不成为权威订单状态。
- restart实际走现有maker_cycle v2 checkpoint/restore，带当前next_sequence；capture重放逐帧再次运行上述组件并比较决策/规范状态，检测输入与决策篡改，墙钟耗时不比较。
- 继承预登记Protocol的帧数/时长/负载/计算/容量/新鲜度/缺口门槛和版本变化统计；报告始终qualification=false。

## 合成输入及命令

合成输入由 `test_arbitrage_maker_shadow.fixture` 以及11/14现有公开夹具生成；Protocol.version=synthetic-maker，code_hash=a×64仅为合成标记，calibration_ref=pending-13，不是冻结真实参数。原始Frame必须与捕获JSON及冻结Session依赖共同归档；JSON不是自包含研究场景或真实市场记录。

- `python -m unittest discover -s python -p 'test_arbitrage*shadow.py'`：19/19（Maker9 + 原14十项），通过。
- `python -m compileall -q python/arbitrage_shadow.py python/arbitrage_maker_shadow.py python/test_arbitrage_maker_shadow.py`：通过。
- `python -m unittest discover -s python`：230/230，通过。
- 双轴code-review：Standards无文档硬违例；一项可选P3为活动Cycle白名单predicate与Admission字段检查部分重复。保留建议，不为去除少量重复扩大本票修改Admission核心；后续审批字段变化须同步核对两处。Spec初审一项P2（InvalidLatched未进入真实Cycle退出锁存）已通过公开先失败回归修复，补审无剩余发现。新增回归覆盖终态覆盖、checkpoint恢复后持续受控减仓和实际重放。
- `git diff --check`：通过。

## 证据边界与未执行

公式/执行建议正确性：本票合成回归及11既有公共测试，不能替代真实校准；统计有效性：13仍pending；真实运行资格：本票pending，未运行真实Host/MarketFeedAdapter/VenueAdapter、真实规范行情采集、预登记长期负载或真实观察验收。

所有Maker虚拟成交、对冲和输出均为counterfactual_simulation；actual_fills/actual_pnl/queue_evidence=not_observed。L2不证明真实排队；合成Fill/在途量由夹具注入，不构成真实成交、实际收益或经济账本。等待/隐性流动性、撤单竞态、迟到Fill、部分成交/Unknown、对冲失败、费用资金费及真实发送延迟仍需独立实证。没有这些观察样本，不关闭15，不继承双IOC资格或绕过13依赖。
