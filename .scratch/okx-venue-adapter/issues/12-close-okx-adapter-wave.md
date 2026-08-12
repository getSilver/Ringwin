# 形成可复现证据并关闭 OKX Adapter 波次

Type: task
Status: resolved
Assignee: Codex
Blocked by: 11
Parent: [产品化接入 OKX Venue Adapter](../map.md)

## Question

如何由 SystemOwner 核验已冻结的全部验收轨迹、Demo 安全清理、证据边界、README 复现入口和未资格事项，并在不混入下一 Venue 或生产工程工作的前提下关闭本地图、选择下一能力波次？

## Answer

SystemOwner 以提交 `3cb51c7` 上的单一入口重新核验第 11 票，而不是沿用先前进程内状态。系统异常关闭后的首次独立 preflight 已证明 Demo 账户无遗留；随后默认只读整波与显式 `-DemoLive` 整波均重新成功，最后再独立执行 preflight。关闭时的账户事实为：

```text
environment=demo qualified=true pending_orders=0 pending_algo_orders=0 open_positions=0 liabilities=0 funded_currencies=USDT
```

本波交付边界如下：

- 唯一产品 seam 仍为四操作、有界异步 `VenueAdapter`；TradingShard 不接触 OKX REST/WSS、认证或 venue 字段，SimulatedVenue 继续通过同一 seam。
- 固定 libcurl 8.21.0/Schannel 单 transport owner 承载 Windows HTTPS、public/private WSS、代理、严格 TLS、取消和 owner-thread handle 生命周期；Zig 标准库只承担签名、JSON 和规范状态。
- BTC-USDT SPOT 与 BTC-USDT-SWAP isolated/net 的 Instrument、L2、参考价、资金费率、私有订单/成交/余额/仓位/margin/account facts 均以 RawIngress 优先和稳定身份进入 CanonicalEvent。
- 九 REST endpoint 分页双读屏障覆盖启动、重连与 Unknown；orders 使用 `ordId`，fills 使用 `billId`，缺口、冲突、未归属活动订单或未关闭 Unknown 均撤销新增风险权限。
- 既定 Limit、Market、GTC、IOC、FOK、Post-only、VenueReduceOnly、原地 amend、授权 CancelConfirmCreate、逐项 TransportBatch、限流、稳定拒绝及 NotSent/Submitted/Unknown 已闭合；禁止静默降级、组合 cancel-replace、重叠替换和自动重放交易 POST。
- 固定 Strategy 的 `OrderIntent -> Gateway -> TradingShard cash risk -> OrderCommand -> OKX Demo -> private facts -> 双层经济投影 -> stable replay` 已真实运行；买入和反向清理均完成，最终零仓位、零 OpenCost 和零账户残余。
- 断连、L2 缺口、认证失败、限流、超时 Unknown、逐项部分成功、amend 并发 Fill、重复/乱序/迟到回报、REST 分页及清理失败已在既有 ingress、dispatch、reconciliation、projection seam 以确定性 fixture 证明失败关闭。

可复现操作入口只保留三条：

```powershell
tools\verify-okx-demo-wave.ps1                         # 默认只读整波
tools\verify-okx-demo-wave.ps1 -DemoLive               # SystemOwner 显式授权的 Demo 成交整波
tools\run-okx-demo-live-acceptance.ps1 -CleanupOnly    # 异常后仅 BTC 残余的显式恢复
```

关闭复验中，Debug、ReleaseSafe、ReleaseFast 各 48 项核心测试、libcurl 35 项合同、确定性四轨 digest、公共 HTTPS、private WSS、REST 分页稳定屏障及 `x86_64-linux-gnu` compile-only 全部通过。最新 Demo-live 证据为：

```text
environment=demo strategy=fixed-btc-usdt-ioc orders=2 cleanup=closed position_atoms=0 open_cost_atoms=0 raw_ingress=44 stable_records=16 replay_digest=113d0b3e1df0398aefd42378e8d004f218fbcb81af1b65c73e4eb47120e92c3a
okx_demo_wave_acceptance=passed mode=demo_live linux=compile_only production_qualification=false
```

该真实 Demo digest 绑定本次订单、成交和时间身份，不应跨运行固定；必须稳定的是每次运行内部的 live/replay 等价和离线四条权威 digest。

明确未资格：OKX 生产账户与生产下单、真实资金、Linux libcurl OpenSSL/CA artifact 的冻结链接与运行、Linux 性能、生产部署/密钥托管、单活热备/fencing、币本位/双向持仓/组合保证金/期权/算法单，以及 ETH-USDT、ETH-USDT-SWAP 和其他 Instrument。`.env.local`、libcurl 构建目录和 Linux 对象继续由 Git 忽略；未发现 SecretMaterial 或生成物进入提交。

因此本地图在当前 Demo 功能范围内关闭，不继续混入 OKX 生产工程或下一 Venue 实现。按已冻结的首批 Venue 顺序 `OKX -> Binance -> Gate.io -> Bitget`，下一能力波次选择 **Binance Venue Adapter 最小纵向接入**；它需要独立地图和独立 SystemOwner 范围确认，不在本提交中预建代码或通用插件框架。
