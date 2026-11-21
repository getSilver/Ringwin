# 07 跨所策略以空交易名单启动

Type: task
Status: in-progress
Assignee:
Blocked by: 无
Parent: [模块地图](../map.md)

## Question

没有批准记录时核心如何处理开仓？

## What to build

StrategyInstance 加载即读取名单，每次新增开仓检查有效批准。

1. **Web 策略实例连接**。默认 Web 启动器通过现有控制通道连接正式 engine 的策略实例权威服务。实例加载时直接读取生效的交易名单。
2. **engine 输入恢复**。正式 Linux engine 恢复 Writer 的决策日志后，由对应 Venue adapter 补处理已持久化、尚未提交到决策日志的输入。恢复完成前保持 `RecoveryOnly`。
3. **StrategyHost 输入链**。正式 engine 按订阅和 ShardSequence 将已提交事件组装成连续覆盖的批次，经现有有界 pipe 交付给 StrategyHost。实例从 checkpoint 无权重放，应用核心提交的 `HostActivated` 后回执对应的 ShardSequence。

双 IOC 开仓、退出及对账由 [11](11-dual-ioc.md) 验收，单腿失败后的敞口恢复由 [12](12-ioc-recovery.md) 验收。

## 验收条件

- [x] 首次启动、撤销最后一项和重启均拒绝新开仓，无需开启白名单开关。
- [x] 用已有敞口验证撤单和减仓仍可进行。
- [ ] 默认 Web 入口通过正式 engine 加载实例和名单。有条目时显示清单，空名单时显示“策略交易名单为空，请从跨所机会扫描器添加配对”。权威连接或名单读取失败时显示错误。
- [x] 在 Venue 输入持久化后、决策提交前终止 engine。重启后补提交该输入，重复恢复只产生一次权威结果。输入恢复失败时维持 `RecoveryOnly`。
- [ ] StrategyHost 从已有 checkpoint 追平核心指定的屏障。验收记录包含重放起点、批次覆盖区间以及 `HostActivated` 对应的回执；该回执前策略输出无法进入风控。
- [ ] 使用同一套 Linux 正式入口和隔离状态目录串联以上三项，记录复现命令、运行环境、输入来源、决策提交屏障和 Host 回执。只运行本次变更涉及的定向测试及这条 Linux 进程链。

## 实现与证据

实例加载时向核心读取有效名单状态。启用前，核心按实例绑定的部署账户识别跨 Venue 范围并持久记录，开仓和增险改量均检查有效批准。

Windows 离线回归使用两个模拟 Venue、持久日志、合成订单回报和规范成交，验证首次空名单、撤销最后一项和重启后拒绝开仓，已有挂单可撤，成交后的敞口可用 reduce-only 订单减仓。

已有权威连接的 Web 策略页支持空名单提示，内置页面和 RingwinUi 均已接入。默认 `python/control_plane_node.py` 启动路径仍缺策略实例权威连接和发布管理器。正式 engine 恢复 Writer 后维持 `RecoveryOnly`，直到所有配置的输入源通过恢复校验。正式 `market_feed` 角色使用 OKX 公共行情 adapter 重放自己的 RawIngress，控制器通过现有 Unix 通道转交规范输入。正式 Linux 进程链联合验收仍待完成。

### 本轮定向验证

- WSL1 Ubuntu 20.04 使用正式 `engine` 和 `market_feed` 入口及各自的隔离状态目录。合成 OKX 协议输入包含产品定义和订单簿快照。空回放或缺少 capture 时返回 `RecoveryOnly`。RawIngress 提交序号 2 后、engine 决策提交仍为 65 时发送 SIGKILL。重启由 adapter 解码并补提交 3 条规范输入，Writer 屏障为 68。再次重启重放，65 后的决策记录逐字节一致，屏障仍为 68。此证据覆盖已配置的 OKX 公共行情恢复。

- Windows 启动 Zig 正式 engine 定向回归，验证 Writer 恢复、已提交记录的连续读取、空名单和有效批准。独立的 OKX 私有恢复回归验证部分决策已提交时仅补一次缺失 Fill。
- WSL1 Ubuntu 20.04（内核 4.4.0-17763-Microsoft），隔离状态目录和合成双账户 Writer。正式入口 `--production-role engine --state-dir` 通过只读中继连接实际 Web 进程。实际 OwnerSession 登录后，验证空名单、无效实例和 SIGKILL 断连。engine 报告 `VenueRecoveryNotConfigured` 并保持 `RecoveryOnly`。WSL 自带 Python 3.8 使用临时 `sitecustomize` 将 `functools.cache` 映射到 `lru_cache(maxsize=None)`。
- HTTP 定向测试覆盖名单协议和错误。实例定向测试覆盖重载和并发读，内置页面定向测试覆盖空名单、有条目及错误显示。

从仓库根目录构建两个相关 Linux 入口：

```powershell
zig build-exe src/main.zig -target x86_64-linux-gnu -O Debug -fstrip --stack 67108864 '-femit-bin=.scratch/build/production-07/formal-engine'
python tools/zig-entry.py build-exe src/testing/acceptance/platform/production_engine_fixture.zig -target x86_64-linux-gnu -O Debug --stack 134217728 '-femit-bin=.scratch/build/production-07/provision'
```

在 Linux 上由有权连接正式 role 的控制器身份运行，使用支持 `functools.cache` 的 Python：

```bash
python3 python/verify_production_strategy_web.py .scratch/build/production-07/formal-engine .scratch/build/production-07/provision
```

定向崩溃验收使用相同的两个 Linux 二进制入口：

```bash
python3 python/verify_production_venue_recovery.py .scratch/build/production-07/formal-engine .scratch/build/production-07/provision
```
