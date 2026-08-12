# 资格化 OKX Demo 波次并保持 Linux 构建

Type: task
Status: resolved
Assignee: Codex
Blocked by: 10
Parent: [产品化接入 OKX Venue Adapter](../map.md)

## Question

如何形成一条失败即停、可复现且不泄露凭证的 Windows 自动验收入口，证明离线合同、公共行情、完整 Demo 订单能力、端到端投影、恢复和清理全部通过，同时证明 `x86_64-linux-gnu` 可交叉构建并明确不宣称 Linux 性能或生产资格？

## Answer

新增唯一整波入口 `tools/verify-okx-demo-wave.ps1`。默认运行只读资格，只有显式传入 `-DemoLive` 才会发送 Demo 交易写请求；两种模式均失败即停，并按固定顺序验证：

1. 当前平台必须是 Windows，Zig 必须精确为 `0.17.0-dev.315+5b647b792`，全部 `src/*.zig` 必须通过 `zig fmt --check`。
2. `src/main.zig` 的 Debug、ReleaseSafe、ReleaseFast 各 48 项合同测试，以及 ReleaseSafe 确定性演示及四条固定 digest 全部通过。
3. 固定 SHA-256 下载并构建 libcurl 8.21.0/Schannel；已有规范构建产物时复用，缺失时才 bootstrap。随后验证锁定版本、TLS backend、WSS 能力及 OKX public HTTPS 200。
4. `src/main.zig` 完成 `x86_64-linux-gnu` ReleaseSafe 无产物交叉构建；完整 OKX Demo acceptance Zig 源码与 C shim 生成 Linux 目标对象，证明 Adapter 源码可编译。Linux 目标并未链接或运行尚未冻结的 OpenSSL/CA artifact。
5. Demo preflight 验证专用 Key、Demo header、global/Futures/net/isolated 配置、双 Instrument 白名单、25 USDT 上限及零挂单/仓位/负债；随后同一产品 acceptance 完成 private WSS、九 REST 端点两轮稳定分页、固定策略 OrderCommand、投影、恢复和清理。

只读入口：

```powershell
tools\verify-okx-demo-wave.ps1
```

会成交入口（必须由 SystemOwner 显式启用）：

```powershell
tools\verify-okx-demo-wave.ps1 -DemoLive
```

若异常运行后 preflight 报告仅有 BTC 残余，先停止普通整波，只允许显式恢复入口：

```powershell
tools\run-okx-demo-live-acceptance.ps1 -CleanupOnly
```

脚本不接收凭证命令行参数，只把被 Git 忽略的 `.env.local` 中三项 Demo secret 临时注入子进程环境，并在 `finally` 清除；输出不打印 secret。交易入口仍固定 ReleaseSafe，发送前与 finally 后都执行 preflight，任何 Unknown、分页、账户、投影或清理不确定均失败关闭。

本次只读整波成功：

```text
phase=private_stream ok
phase=bootstrap ok
phase=baseline ok
phase=strategy_order_command ok
okx_demo_wave_acceptance=passed mode=read_only linux=compile_only production_qualification=false
```

既有 SystemOwner `--demo-live` 授权下，会成交整波亦成功：

```text
environment=demo strategy=fixed-btc-usdt-ioc orders=2 cleanup=closed position_atoms=0 open_cost_atoms=0 raw_ingress=44 stable_records=16 replay_digest=03dc8faeebab8c654d372ce971b2a4d3cbb0a5fcbcc10667bdb06825138706c2
okx_demo_wave_acceptance=passed mode=demo_live linux=compile_only production_qualification=false
```

最终 preflight 再次证明零挂单、零衍生品仓位、零负债及 USDT-only 无 BTC 残余。此结论只授予当前 Windows 开发节点上的 OKX Demo 功能资格和 Linux compile-only 证据；它明确不授予 Linux 运行时、性能、testnet 收益、生产账户或生产部署资格。
