# 11 从前端批准跑通双 IOC 完整周期

Type: task
Status: resolved
Assignee:
Blocked by: [05 USDT/USDC 平价估值与汇差归因](05-stablecoin.md)、[08 从机会页将一条路线加入指定策略](08-approve.md)、[10 让策略限价准确到达 Gateway](10-limit-price.md)
Parent: [模块地图](../map.md)

## Question

同一笔人工批准能否贯穿一次完整开平仓？

## What to build

从空配置经正式前端扫描、批准、开仓前复核和双腿路由，追踪同一策略周期直到退出对账。使用 [08](08-approve.md) 提供的可信账户绑定，将 [04](04-fees.md) 的当前费率源接入正式 StrategyHost，在批准路线的开仓前复核两腿费率版本。

## 验收条件

- [x] 使用实际运行组装，逐腿核对账户、产品、环境、方向、最终价格、数量与原始订单身份。
- [x] 用同一条已批准路线验证费率更新后的正式开仓复核。旧版本或缺少任一腿费率时不得产生开仓动作；当前版本通过费率复核后继续走既有准入及双腿路由。
- [x] 双腿成交后核对持仓与退出，原币费用、返佣及独立汇差与周期账务一致。
- [x] 记录测试环境、场所、输入及回执来源，区分离线、Demo/Testnet 与实盘证据。

## 进展

- Admission、准入交接和首笔开仓动作从磁盘读取已发布的人工费率。每批准入共享同一份快照，交接和首笔开仓分别复核当前版本及两腿的场所、账户和产品。策略 checkpoint 保留费率版本对应的场所。旧 checkpoint 若只有费率版本且仍处于空闲，须重新准入以建立完整费率绑定。
- Python 回归使用两个独立的费率读写实例，覆盖更新后拒绝旧版本、版本相同但缺腿、两腿齐全后继续准入，并验证已恢复的周期在拒绝时保留空闲状态和原意图序号。
- Windows 离线定向集成使用 Zig ReleaseSafe、两个合成场所（Venue 1 × 21，环境均为 simulation）、账户 20 × 30 和品种 101 × 102。公共盘口来自 canonical 深度夹具，费率从临时状态目录读取，批准条件由 Python 夹具提供。同一 ManagedHost 对旧版本与缺第二腿版本均未发布开仓帧，当前完整版本经 Writer 生成双 IOC，模拟 Gateway 捕获买入 100 ticks 和卖出 110 ticks、各 10,000 lots，并与 OMS 的订单 ID 和客户端订单 ID 一致。合成回执经持久化后恢复到 holding。未使用 Demo/Testnet 或实盘连接。
- 正式 Host 现将激活后的输出交给 Writer。配置 `strategy_host.manual_fees` 后，子进程用 Writer 提供的部署场所、账户和产品逐腿复核费率。拒绝时恢复回调前的私有状态和意图序号，Writer 屏障仅增加该条公共输入。
- Windows 离线联合验收从空扫描范围出发，经 OwnerSession 和认证 Web API 保存费率、配置扫描、展示合成盘口评估并批准身份 98765。正式 Host 拒绝费率版本 1 和缺腿版本 2，版本 3 经 Writer 和独立的 Gateway 实例生成双腿 IOC。场所 1 × 21 均为 simulation，使用合成生产合同回执与原订单 ID，账户 20 × 30、isolated_linear 品种 101 × 102，各 10,000 lots。开仓后分别持有 +10,000 和 −10,000 lots，退出后归零。两账户原币分别扣 10、返 4 个原子单位，最终为 394 USDT 原子单位和 594 USDC 原子单位。闭合证明和 FX 归档绑定周期首意图 7，以 0.998 回放得独立汇差 3/250000000 USDT。
- 这批 Windows 证据由测试入口组装 Host、Writer 和 Gateway，策略触发和对账数据使用离线夹具。独立进程路由及批准评估交付见下方 Linux 证据。

## 远端 Linux 复验

- 在指定 SSH 主机的隔离目录 `/root/rw11-acceptance-TQ5UyL` 运行。环境为 x86_64 Linux 5.10.0-15-amd64 和 Python 3.9.2。源基线为 `9700e294`。远端 `fee.log` 记录 4 项费用测试通过；`dual-ioc.log` 记录批准 98765、旧版本及缺腿拒绝、周期 7 的四笔 IOC、原币费与返佣、归零闭合、独立汇差 3/250000000 USDT。Gateway 在该离线验收中由测试入口组装，场所均为 simulation。
- 正式角色旧格式单腿输出回归首次失败于 `JointAdmissionRequired`。联合域的 Writer 入口现将该格式提交为明确拒绝。带精确价格的单腿减仓仍可经版本化组信封进入既有准入。
- 同机 `strategy-chain-corrected.log` 记录正式 engine、market_feed 和 Web 的定向联合回归通过。Host 首次确认 69，重建后确认 73，接入新盘口后 Writer 到达 76，旧回执被拒绝，已提交前缀一致。更新后的 Linux 二进制和 Host 源文件散列记录在 `corrected-sha256.log`。

## Answer

- Web 在校验 Writer 批准回执后发布批准评估。正式 Host 加载的离线验收包读取同一批准、评估摘要及部署腿，使用评估中的方向、模型和收益目标形成开仓动作。完整费率版本恢复两腿费率后运行相同扫描评估，Host 读取该版本的更新评估。
- 远端 `dual-ioc-routed.log` 验证批准 98765，首意图 7。旧费率和缺腿均未提交开仓。完整版本产生两笔开仓和两笔减仓。Writer 提交快照经受信 Unix 通道送入独立的正式 `execution_gateway`。实际模拟适配器的回执回写到同一个 Writer，逐腿核对账户 20 × 30、isolated_linear、simulation、品种 101 × 102、方向、规则版本 2 的 100 ticks、10,000 lots 和原订单身份。持仓归零，原币费用与返佣合计 −6 原子单位／账户，独立汇差为 3/250000000 USDT。Gateway 正常排空并退出。
- 同机 `strategy-chain-routed.log` 验证正式 engine 的提交快照导出、Venue 恢复、Host 激活回执和 Web 投影。双 IOC 验收由测试入口持有同一个 Writer 并驱动快照及回执中继。策略包的信号、规模和退出触发来自离线夹具，未使用 Demo、Testnet 或实盘凭证。异常回执和重启后的恢复由 [12](12-ioc-recovery.md) 验收。
