# 16 扫描控制台实施与验收

日期：2026-11-07（Asia/Shanghai）。用户授权整张16的实施，随后明确排除真实行情联调和浏览器验收。未部署、未调用交易所、未执行真实或Demo交易、未同步GitHub。

## 工作区与起点

- Ringwin：`D:/github/Ringwin-scanner`，分支 `spread-arbitrage-strategy-python`。先快进至已提交的main `937587450acd5ccf09a3c733e07f98f64bb0c4fd`，复用现有Web／原生权威路径。
- RingwinUi：`D:/github/RingwinUi-scanner`，同名分支，起点 `3abcf04a5d3608b6875aa16776a73c7984b7865e`。复用原页面与Astryx组件，并承接原工作区已有独立Demo源文件。
- 两个原工作区的凭证、控制面及其他未提交改动未搬移、撤销或提交。
- 已提交实现：Ringwin `26c25896`、`07a8a762`、`42b83f24`；RingwinUi `b3fbc33`、`9846dd1`。未push。

## 实现

- Python `arbitrage_scanner.scan`新增可选版本化Scope，兼容无Scope调用。按规范Venue／产品／环境／资产过滤；空纳入为全部登记资产，排除优先。每腿最多8档买卖各自名义金额累加取小值，使用精确分数比较包含边界；空上／下限与0分开，未知数量不达标。仍校验原观察与原Plan绑定。
- `scanner_console`持有独立只读扫描会话、期望／实际状态、配置乐观版本、共享订阅所有权和有界输入队列。新范围预热，移除撤销相应候选；无行情也由后台刷新TTL。默认重启停止；旧会话、乱序及同身份异内容拒绝。
- `scanner_history`单写入线程保存SQLite派生记录；批次／事件原子提交、完整替换序号幂等、存储失败／溢出／重启缺口、自然结束和观察中断区分。查询分页及事件筛选、UTC按事件汇总、内容寻址的完整输入材料、实际重放、引用锁定、明细／证据清理和一致性备份由服务端处理。
- 现有`ControlPlaneApp`提供`/api/scanner`，所有读写经过OwnerSession与CSRF；HTTP不能提交市场输入或核心回执。可选静态资产服务用于同源RingwinUi构建。
- 核心新增`PairTradingAuthorization`，验证两腿Venue／Environment／Account／Instrument／规则、策略激活、配置、组合归属及模式能力。核心持久提交后才确认版本／屏障；稳定请求身份用于重复与结果查询。撤销不清理OMS或经济状态；Gateway发送前复核批准版本，撤销不开放新增风险发送。
- 核心状态布局变化：journal 52→53、state 56→57、registry 50→51、StateDigestV15→V16。native构建清单同步；旧快照／日志不隐式升级。经济与稳定回放断言保持后重采固定验收摘要。
- RingwinUi正式入口 `/?scanner=live#opportunities`，独立内存Demo `/?demo=scanner#opportunities`，原页面继续可访问。两者支持多Venue×产品、空纳排及深度区间；正式金额精度来自节点资产定义，以整数处理。候选证据与两腿产品、范围草稿／生效、历史／缺口／核心请求分别显示。

## 实际验证

- 扫描与控制台公开回归：20项通过，含新增品种策略的完整输入重放。
- `python python/verify_scanner_console.py`：`scanner_web_core_offline=passed`，使用真实离线Zig authority，覆盖接受、幂等、错误归属、旧版本拒绝、撤销、停止和历史；另注入核心已提交但回执丢失，验证unknown后按原身份查回accepted。
- `python tools/zig-entry.py test src/testing/acceptance/core/scanner_authorization_acceptance.zig -lc -OReleaseSafe --stack 536870912 --test-filter 'scanner '`：6/6通过。覆盖接受／拒绝不变性／幂等／撤销／DurableStore快照恢复，部分成交后的剩余数量增量、native方向和reduce-only伪装拒绝，以及取消确认后的增量替换拒绝／减量替换保留。
- `zig build strategy-authority-probe -Doptimize=ReleaseSafe --summary all`：6/6步骤成功；使用重新构建的probe复跑Web→核心离线验收成功。
- 初次Zig全量：882/885通过，三项失败均为新增schema／digest后的固定版本或摘要pin未更新；已按通过经济与回放断言后的实际摘要更新，最终全量已确认修复。
- 补跑Zig全量888/889：旧现货减量native amend回归失败，原因是新增reduce-only一致性比较早于风控自动推导标记；已将检查移到有效标记推导之后。`zig test src/main.zig -OReleaseSafe --stack 536870912 --test-filter 'scanner ' --test-filter 'spot decreasing native amend'`：8/8通过（含主入口2项），同时覆盖旧兼容行为和全部扫描批准回归。
- **最终全量**：`zig build test -Doptimize=ReleaseSafe --summary all`，6/6步骤成功，**889/889测试通过**；日志`.scratch/build/scanner-zig-verified.log`。主测试编译8分钟、运行65分钟；bounded IO验证通过。
- 初次Python全量：358项，失败来自独立工作区缺少完整`zig build`产物；完整ReleaseSafe构建9/9步骤成功后补跑：`python -u -m unittest discover -s python -p test_*.py`，358项中355项通过、3项跳过，1476.990秒。核心审查修复后，扫描／控制台20项及重新构建probe的Web→核心验证再次通过。
- RingwinUi：`npm.cmd run typecheck`、`npm.cmd run build`、`node src/scanner/scannerApi.check.mjs`、`node src/scanner/scannerDemoModel.check.mjs`均通过。构建仍提示主bundle超过500kB。
- 双轴审查已执行并完成复核，当前源码无待处理P1/P2。修复状态展示Token、请求超时与轮询重叠、跨时钟TTL与完整往返耗时、重放输入身份及live配置隔离；核心增补部分成交／改单／取消确认后替换的撤权检查。审查结论不代替运行验收。
- 浏览器尝试未通过：两次均在查找“扫描范围”tab时超时；页面已登录并显示Stopped。用户随后明确不处理浏览器验收，已停止且不再补跑，不能据此声明界面交互通过。

## 边界

真实行情联调按用户明确要求未执行，浏览器验收已停止。节点接线须提供可信登记目录、CanonicalSource订阅回调及deliver输入、冻结计划与NativeAuthority；离线验收使用确定性规范输入和真实Zig核心，不证明Venue生产输入接线。适配器源码能力与离线合同不能替代真实连接、吞吐、经济或运行资格。12–15的pending资格不因本次交付改变。保留期限与队列容量的部署选择仍须运行测量，当前边界显式失败，不静默丢弃。
