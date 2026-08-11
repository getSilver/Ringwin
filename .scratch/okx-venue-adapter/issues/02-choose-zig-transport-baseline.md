# 选择 Zig 0.17 OKX 传输基线

Type: research
Status: open
Assignee:
Blocked by:
Parent: [产品化接入 OKX Venue Adapter](../map.md)

## Question

在当前固定 Zig `0.17.0-dev.315+5b647b792`、Windows 开发验收、`x86_64-linux-gnu` 交叉构建和不自研 TLS/WebSocket 的约束下，哪些第一方或上游原始资料能够证明可用的 HTTPS、WebSocket、代理、证书校验、超时、取消与连接恢复方案；满足 OKX REST/public/private WS 的最小依赖组合是什么？

研究优先 Zig 标准库及候选依赖的官方源码和文档；结论写入 [`research/02-zig-transport-baseline.md`](../research/02-zig-transport-baseline.md)。
