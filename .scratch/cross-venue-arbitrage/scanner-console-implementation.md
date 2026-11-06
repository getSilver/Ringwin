# 16 扫描控制台实施与验收

日期：2026-11-07（Asia/Shanghai）。用户授权整张16的实施，随后明确排除真实行情联调。未部署、未调用交易所、未执行真实或Demo交易、未同步GitHub。

## 工作区与起点

- Ringwin：`D:/github/Ringwin-scanner`，分支 `spread-arbitrage-strategy-python`。先快进至已提交的main `937587450acd5ccf09a3c733e07f98f64bb0c4fd`，复用现有Web／原生权威路径。
- RingwinUi：`D:/github/RingwinUi-scanner`，同名分支，起点 `3abcf04a5d3608b6875aa16776a73c7984b7865e`。复用原页面与Astryx组件，并承接原工作区已有独立Demo源文件。
- 两个原工作区的凭证、控制面及其他未提交改动未搬移、撤销或提交。

## 实现

- Python `arbitrage_scanner.scan`新增可选版本化Scope，兼容无Scope调用。按规范Venue／产品／环境／资产过滤；空纳入为全部登记资产，排除优先。每腿最多8档买卖各自名义金额累加取小值，使用精确分数比较包含边界；空上／下限与0分开，未知数量不达标。仍校验原观察与原Plan绑定。
- `scanner_console`持有独立只读扫描会话、期望／实际状态、配置乐观版本、共享订阅所有权和有界输入队列。新范围预热，移除撤销相应候选；无行情也由后台刷新TTL。默认重启停止；旧会话、乱序及同身份异内容拒绝。
- `scanner_history`单写入线程保存SQLite派生记录；批次／事件原子提交、完整替换序号幂等、存储失败／溢出／重启缺口、自然结束和观察中断区分。查询分页及事件筛选、UTC按事件汇总、内容寻址的完整输入材料、实际重放、引用锁定、明细／证据清理和一致性备份由服务端处理。
- 现有`ControlPlaneApp`提供`/api/scanner`，所有读写经过OwnerSession与CSRF；HTTP不能提交市场输入或核心回执。可选静态资产服务用于同源RingwinUi构建。
- 核心新增`PairTradingAuthorization`，验证两腿Venue／Environment／Account／Instrument／规则、策略激活、配置、组合归属及模式能力。核心持久提交后才确认版本／屏障；稳定请求身份用于重复与结果查询。撤销不清理OMS或经济状态；Gateway发送前复核批准版本，撤销不开放新增风险发送。
- 核心状态布局变化：journal 52→53、state 56→57、registry 50→51、StateDigestV15→V16。native构建清单同步；旧快照／日志不隐式升级。经济与稳定回放断言保持后重采固定验收摘要。
- RingwinUi正式入口 `/?scanner=live#opportunities`，独立内存Demo `/?demo=scanner#opportunities`，原页面继续可访问。两者支持多Venue×产品、空纳排及深度区间；正式金额精度来自节点资产定义，以整数处理。候选证据与两腿产品、范围草稿／生效、历史／缺口／核心请求分别显示。

## 实际验证（收尾中）

- 扫描与控制台公开回归：19项通过。
- `python python/verify_scanner_console.py`：`scanner_web_core_offline=passed`，使用真实离线Zig authority，覆盖接受、幂等、错误归属、旧版本拒绝、撤销、停止和历史。
- Zig配对批准公开验收：接受／拒绝不变性／幂等／撤销／DurableStore快照恢复通过。
- 初次Zig全量：882/885通过，三项失败均为新增schema／digest后的固定版本或摘要pin未更新；已按通过经济与回放断言后的实际摘要更新，待最终全量复核。
- 初次Python全量：358项，失败来自独立工作区缺少完整`zig build`产物；完整ReleaseSafe构建9/9步骤成功后已补跑全量，待结果。
- RingwinUi类型检查、金额精度自检、原Demo状态自检与生产构建通过；浏览器和双轴审查待收尾。

## 边界

真实行情联调按用户明确要求未执行；适配器源码能力与离线合同不能替代真实连接、吞吐、经济或运行资格。12–15的pending资格不因本次交付改变。保留期限与队列容量的部署选择仍须运行测量，当前边界显式失败，不静默丢弃。
