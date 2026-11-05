# 03 在实际发送前复核 DispatchDeadline

Type: task
Status: resolved
Assignee: Codex
Blocked by:
Parent: [模块地图](../map.md)
Labels: ready-for-agent
Evidence level: 两家慢签名器反例已复现，F3

## Question

如何保证签名等耗时操作结束后，命令仍在允许首次发送的单调期限内？

## Problem Statement

Binance/Bybit 签名前检查期限，签名后直接提交。注入签名器把时钟从 1 推进至 11，两家仍首次发送已过期命令。

## Solution

实际 transport 副作用前基于新的单调时钟复核期限；过期明确未发送，不延长原许可或自动重试。

## User Stories

1. 作为策略所有者，我希望慢签名后过期的命令不发送，以免执行陈旧决策。
2. 作为执行人员，我希望批次逐条检查，以免前一条耗时使后一条越界。
3. 作为安全负责人，我希望使用单调时钟，以免墙钟变化影响许可。
4. 作为运维人员，我希望过期拒绝明确 not_sent，以免不必要地进入 Unknown。
5. 作为策略所有者，我希望期限内命令只发送一次，以免检查引入重试。
6. 作为恢复执行者，我希望重放不延长期限，以免旧许可恢复成新权限。
7. 作为执行人员，我希望撤单遵守其自身期限，以保留保护命令的正确性。
8. 作为维护者，我希望用注入时钟检查临界值，以免依赖真实等待和网络。

## Implementation Decisions

- 最终检查晚于签名及其他发送前耗时工作，紧邻各 adapter 的实际提交。
- 沿用当前 adapter 的 now >= deadline 到期规则并覆盖等值；不将期限解释成 Venue 订单存活期。
- 保留版本、权限、session/fencing 的现有所有者，不合并为伪造的统一证明。
- 确定未调用 transport 时记 not_sent；transport 后的歧义继续按 Unknown 处理。
- 不延长期限、改命令身份或自动重签重试；参考已有 Hyperliquid 最终检查模式，不复制其私有协议。

## Testing Decisions

- 从 Gateway/VenueAdapter 公共发送入口进入，由签名器推进注入时钟，观察真实 transport 调用数。
- 复用 expired command 与共享 adapter 生命周期验收，不只测试比较函数。
- 覆盖期限前、等于期限、期限后，签名失败、正常签名及批次第二条过期。
- 如还有原文持久化等耗时阶段，在其返回点推进时钟，验证检查位于其后。
- 检查规范输出、命令身份、既有 Unknown 和重放零发送，保留期限内正例。

## Acceptance Criteria

- [x] 两家原慢签名反例均不发送，返回既有到期拒绝结果。
- [x] 等于期限时拒绝，期限内合法命令只发送一次。
- [x] 批次逐条复核，不复用批次开始时刻。
- [x] 无延长许可、自动重试或清除 Unknown 的绕过路径。
- [x] Gateway 与 Hyperliquid 相关正例不回退，未发送与不确定发送继续区分。
- [x] 本票最小定向回归通过，记录最终检查点及任何仍不可控的耗时窗口；最终 ReleaseSafe 全量按[地图测试安排](../map.md#testing-schedule)统一执行。

## Out of Scope

Venue GTD、自动取消已 Live 订单、新调度器或签名框架。

## Further Notes

遵循 GLOSSARY 的 DispatchDeadline；与 02 独立。来源见[审阅证据](../evidence.md)。
2026-11-04 按用户授权实施；本票仅执行最小 Debug 定向验证。

## Answer

实现基于 `93c7a9ec2e2daae037ca9261223963ed887bf3d0`，源码提交 `4832623d1f3a797ceb42460ba2e6398cb2bd044a`（仅两家 adapter 实现与回归）。

### 实际检查点及行为

- 当前源码复核：Binance `trySend → dispatchOne`、Bybit `trySend → dispatch` 均在逐条 validate 后编码并调用签名器；原先签名后没有期限检查。两家的 RawIngress 持久化仅处理 transport 返回的响应，不存在签名后的发送前持久化阶段。
- 两家均在签名成功后重新读取注入单调时钟，以 `now >= deadline` 拒绝，输出原命令身份及 ClientOrderId 的 `not_sent/deadline_expired`；不消费改单报告引用，不调用 transport，也不记 Unknown。检查后仅有同步本地改单引用消费及请求构造，随后提交 transport。
- 期限和命令身份不变，无重签、自动重试或延长许可；签名失败仍为 `not_sent/venue_unavailable`。transport 后的 Unknown 与响应原文持久化失败路径不变。
- 新增正式回归经 `VenueAdapter.start/trySend/tryDrain`：下单及撤单均从时钟 1 签名推进至 8/9/11、期限 9，覆盖期限前/等于/之后及签名失败的 12 种组合；期限内只发送一次。批次签名逐次将 1 推至 5、再推至 9，首条发送、第二条撤单到期不发送，验证逐条最终检查。
- 检查与 transport 调用之间仍可能被操作系统抢占；transport 回调内部排队、等待或实际 socket 写入时间由 transport 自身负责。本票保证 adapter 提交前最后可控位置复核，不声称时钟采样和网络写入原子化。
- 未修改 canonical、codec、digest 或持久化格式，无格式身份升级或旧格式迁移。

### 定向证据

平台 Windows PowerShell，Zig `0.17.0-dev.315+5b647b792`，全部 Debug、离线、退出码 0。每条命令的末尾输出通过 `Tee-Object` 保存在下列日志；计数均包含一个共享 `entry.test_0`。

```powershell
python tools/zig-entry.py test src/adapters/binance/binance_venue_adapter.zig -O Debug --stack 536870912 --test-filter 'final dispatch deadline' --test-filter 'Binance rejects stale and expired' --test-filter 'Binance Unknown gate' --test-filter 'shared VenueAdapter contract'
# 6/6；.scratch/build/03-binance-debug.log
python tools/zig-entry.py test src/adapters/bybit/bybit_venue_adapter.zig -O Debug --stack 536870912 --test-filter 'final dispatch deadline' --test-filter 'Bybit unknown dispatch' --test-filter 'common VenueAdapter lifecycle' --test-filter 'Bybit place admission does not block cancel'
# 6/6；.scratch/build/03-bybit-debug.log
python tools/zig-entry.py test src/execution/execution_gateway.zig -O Debug --stack 536870912 --test-filter 'Gateway recovers accepted and Unknown together' --test-filter 'Gateway accepted outcome commit failure'
# 3/3；.scratch/build/03-gateway-debug.log
python tools/zig-entry.py test src/adapters/hyperliquid/hyperliquid_venue_adapter.zig -O Debug --stack 536870912 --test-filter 'Hyperliquid durable context cannot' --test-filter 'Hyperliquid uncertain writes' --test-filter 'Hyperliquid VenueAdapter shared lifecycle'
# 4/4；.scratch/build/03-hyperliquid-debug.log
```

两家的边界回归在各自修复前均实际失败：预期 `not_sent`，实际 `submitted`；修复后上述最终定向全部通过。初次独立运行未设栈预算，fixture 在 TradingShard.apply 溢栈；后续对齐 build.zig 的 512 MiB 测试栈预算。`zig fmt --check` 与 `git diff --check` 通过。

Gateway 覆盖 accepted outcome 持久化失败、恢复 accepted/Unknown 与过期权限零重发；Hyperliquid 覆盖 dispatch context 持久化期间到期、共享生命周期及不确定发送。新增测试由 `src/main.zig` 已有两家 adapter import/test 引用进入 `zig build test`，无需额外验收入口。

最终受测文件 SHA-256：

- Binance：`bf301ebe454139cb25289f46c5d82790778a98039108315bbe041a6c02c990ed`
- Bybit：`bdd20f4b122266235205fe49ed3952251a071b6e6ec78cf808345ee99a0ac21a`

规范审查 0 项硬性违规、0 项代码异味；规格审查 0 项发现。本票定向通过；模块最终 ReleaseSafe 待验，05–07 尚未完成。本轮不跑全量，不访问 Demo/Testnet、不读取真实凭证、不验证真实网络写入时限或生产资格。
