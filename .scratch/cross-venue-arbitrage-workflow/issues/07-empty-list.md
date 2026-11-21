# 07 跨所策略以空交易名单启动

Type: task
Status: resolved
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
- [x] 默认 Web 入口通过正式 engine 加载实例和名单。有条目时显示清单，空名单时显示“策略交易名单为空，请从跨所机会扫描器添加配对”。权威连接或名单读取失败时显示错误。
- [x] 在 Venue 输入持久化后、决策提交前终止 engine。重启后补提交该输入，重复恢复只产生一次权威结果。输入恢复失败时维持 `RecoveryOnly`。
- [x] StrategyHost 从已有 checkpoint 追平核心指定的屏障。验收记录包含重放起点、批次覆盖区间以及 `HostActivated` 对应的回执；该回执前策略输出无法进入风控。
- [x] 使用同一套 Linux 正式入口和隔离状态目录串联以上三项，记录复现命令、运行环境、输入来源、决策提交屏障和 Host 回执。只运行本次变更涉及的定向测试及这条 Linux 进程链。

## 实现与证据

实例加载时向核心读取有效名单状态。启用前，核心按实例绑定的部署账户识别跨 Venue 范围并持久记录，开仓和增险改量均检查有效批准。

Windows 离线回归使用两个模拟 Venue、持久日志、合成订单回报和规范成交，验证首次空名单、撤销最后一项和重启后拒绝开仓，已有挂单可撤，成交后的敞口可用 reduce-only 订单减仓。

默认 `python/control_plane_node.py` 通过控制器提供的 `--engine-authority-fd` 只读中继，从正式 engine 的同一次查询读取策略实例和当前有效名单。实例来源为已恢复的 Writer，Web 无需本地实例日志；首次加载无需有跨 Venue 绑定事实或批准历史。仓库验收脚本负责启动控制器中继，生产部署需由其控制器提供此 FD。正式 engine 恢复 Writer 后维持 `RecoveryOnly`，直到所有配置的输入源通过恢复校验。正式 `market_feed` 角色使用 OKX 公共行情 adapter 重放自己的 RawIngress，控制器通过现有 Unix 通道转交规范输入。配置 StrategyHost 后，所有 Venue 恢复成功才启动 Host。正式 engine 从既有 checkpoint 补齐 Writer 序号，提交 `HostActivated`，收到相同序号的无输出回执后，Web 才显示该实例 `Ready`。发布管理和签名交易启用仍由部署与控制流程负责。

### 本轮定向验证

- WSL1 Ubuntu 20.04 使用正式 `engine` 和 `market_feed` 入口及各自的隔离状态目录。合成 OKX 协议输入包含产品定义和订单簿快照。空回放或缺少 capture 时返回 `RecoveryOnly`。RawIngress 提交序号 2 后、engine 决策提交仍为 65 时发送 SIGKILL。重启由 adapter 解码并补提交 3 条规范输入，Writer 屏障为 68。再次重启重放，65 后的决策记录逐字节一致，屏障仍为 68。此证据覆盖已配置的 OKX 公共行情恢复。

- Windows 启动 Zig 正式 engine 定向回归，验证 Writer 恢复、已提交记录的连续读取、空名单和有效批准。独立的 OKX 私有恢复回归验证部分决策已提交时仅补一次缺失 Fill。
- WSL1 Ubuntu 20.04.3 LTS（内核 4.4.0-17763-Microsoft）使用正式 engine 入口、默认 Web 启动器及两个独立的合成双账户 Writer。空名单场景停在已提交序号 65，有效批准场景停在 72。Web 状态目录未写入实例记录。认证 HTTP 验证未登录返回 401，OwnerSession 登录后读取同一个策略实例及相应名单，SIGKILL 断开 engine 后返回 503。两次启动均报告 `VenueRecoveryNotConfigured` 并保持 `RecoveryOnly`。WSL 自带 Python 3.8 使用临时 `sitecustomize` 将 `functools.cache` 映射到 `lru_cache(maxsize=None)`。控制器以 root 连接正式 role 并向 Web 传递只读中继。
- HTTP 定向测试覆盖名单协议和错误。实例定向测试覆盖重载和并发读，内置页面定向测试覆盖空名单、有条目及错误显示。

### 远程 Linux 复验

- 指定 SSH 主机运行 Debian 11.3、Linux 5.10.0-15-amd64、Python 3.9.2。使用源码提交 `846133bf68a4241885584da3ebfdd07ec52bd4b3` 和固定 Zig `0.17.0-dev.315+5b647b792` 交叉构建的正式 Linux ELF。所有验收进程在远程主机运行，使用隔离状态目录。
- 正式 engine 与默认 Web 进程复验通过。合成双账户 Writer 的空名单和已批准配对分别在已提交序号 65 和 72 读取，杀死 engine 后 Web 返回 503。正式 engine 与 `market_feed` 崩溃恢复复验通过。合成 OKX 产品定义和订单簿快照写入 RawIngress 序号 2，engine 决策屏障仍为 65，此时发送 SIGKILL。恢复补提交三条规范输入到 68，再次恢复的决策记录逐字节相同。空回放或缺少 capture 保持 `RecoveryOnly`。
- 远程 Web 与 Venue 恢复串联探针复用同一个隔离 Writer 和 RawIngress 状态目录。断开时 Web 返回 503，Writer 从 65 恢复到 68 后可再次从 Web 读取同一策略实例及空名单，第三次启动的决策记录逐字节相同。
- 远程证据保存在 `/root/rw07-acceptance-9CaQC2/` 的 `environment.log`、`web.log`、`venue.log` 和 `web-recovery.log`。该批证据覆盖 Web 与 Venue 恢复。

在远程证据目录复现：

```sh
cd /root/rw07-acceptance-9CaQC2/src
python3 python/verify_production_strategy_web.py ../formal-engine-web ../provision-web
python3 python/verify_production_venue_recovery.py ../formal-engine-web ../provision-web
PYTHONPATH=python python3 ../verify_remote_web_recovery.py ../formal-engine-web ../provision-web
```

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

### 正式 StrategyHost 和远程联合验收

- 在同一指定远端 Debian 11.3（内核 5.10.0-15-amd64、Python 3.9.2）使用同一套正式 engine、`market_feed`、默认 Web 与隔离 Writer。输入为合成双账户状态、合成 OKX 公共产品定义和订单簿、已有策略 checkpoint。使用 Zig `0.17.0-dev.315+5b647b792` 交叉构建这两个 Linux 可执行文件，所有验收进程在远端运行。
- RawIngress 序号 2 提交后、Writer 屏障为 65 时终止 engine，Web 返回 503。重启后补提交三条规范输入，Writer 到 68。Host 从 checkpoint 65 回放覆盖 66–68，订阅收到 67 的盘口，`NextIntentSequence` 从 7 前进到 8。核心在 69 提交 `HostActivated`，Host 回执 69，回执前进入风控的 Host 输出为零。Web 显示 `Ready`、空名单和关闭的交易授权。
- 再次启动时，旧会话的激活先撤销，随后尝试在 71 提交新激活。注入落后一位的回执，engine 报 `InvalidBatchAck` 并在 72 提交撤销。第 4 代 Host 回放覆盖 66–72，在 73 提交并确认新激活。原 Writer 前缀逐字节一致。接入恢复后的新盘口后，Host 收到序号 74，Writer 提交到 75。停机排空时 Web 显示 `Stopped`。
- 联合验收、Venue 崩溃恢复回归和 Web 空名单／有效名单回归均通过。日志在 `/root/rw07-acceptance-9CaQC2/` 下的 `strategy-chain.log`、`venue-host.log`、`web-host.log` 和 `host-sha256.log`。本次验收覆盖有界 Host 交付与回执，交易授权保持关闭。

在远端证据目录复现：

```sh
cd /root/rw07-acceptance-9CaQC2/src
python3 python/verify_production_strategy_chain.py ../formal-engine-host ../provision-host
python3 python/verify_production_venue_recovery.py ../formal-engine-host ../provision-host
python3 python/verify_production_strategy_web.py ../formal-engine-host ../provision-host
```
