# 选择 Zig 0.17 OKX 传输基线

Type: research
Status: resolved
Assignee: Codex research/zig-okx-transport
Blocked by:
Parent: [产品化接入 OKX Venue Adapter](../map.md)

## Question

在当前固定 Zig `0.17.0-dev.315+5b647b792`、Windows 开发验收、`x86_64-linux-gnu` 交叉构建和不自研 TLS/WebSocket 的约束下，哪些第一方或上游原始资料能够证明可用的 HTTPS、WebSocket、代理、证书校验、超时、取消与连接恢复方案；满足 OKX REST/public/private WS 的最小依赖组合是什么？

研究优先 Zig 标准库及候选依赖的官方源码和文档；结论写入 [`research/02-zig-transport-baseline.md`](../research/02-zig-transport-baseline.md)。

## Answer

选择固定 `libcurl 8.21.0` 作为唯一直接传输依赖，以同一 C ABI 承载 OKX HTTPS REST 与 public/private WSS；Windows 使用 Schannel，Linux 目标使用资格化 OpenSSL/CA artifact，Zig 标准库只负责 HMAC-SHA256、Base64 与 JSON。所有 easy/multi handle 归单一 transport owner，跨线程通过命令队列与 `curl_multi_wakeup` 唤醒，owner 通过移除 handle 取消；断线后的登录、订阅、缺口恢复、Unknown 与 REST 对账仍由 Adapter 状态机负责，禁止自动重放交易 POST。

锁定版 `std.http.Client` 虽有 TLS、系统 CA 与代理，但连接 timeout 字段未接入实际 connect 且没有客户端 WebSocket；`websocket.zig` 当前又缺代理并明确不保证 Windows connect/TLS handshake timeout，均不能单独满足本波次。完整证据、构建约束、验收门槛及 libcurl WebSocket handshake/Linux artifact 的剩余资格雾见 [Zig 0.17 OKX transport baseline](../research/02-zig-transport-baseline.md)。
