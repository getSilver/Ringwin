# 研究 Python 标准库控制面技术基础

Type: research
Status: closed
Resolution: 已完成；成果见 [research/01-python-stdlib-foundations.md](../research/01-python-stdlib-foundations.md)
Blocked by:
Parent: [构建最小控制面与管理操作界面](../map.md)

## Question

为纯 Python 标准库控制面查清以下事实并给出推荐（研究产物写入
`research/01-python-stdlib-foundations.md`）：

1. Web 层：`http.server`（ThreadingHTTPServer）承载单页 UI + JSON API 的能力边界；
   标准库内实现数据刷新的可行路径（轮询、SSE 手写 chunked、WebSocket 不可行时的替代）。
2. 认证：RFC 6238 TOTP 用 `hmac`/`hashlib`/`secrets` 的实现要点与时钟窗口取舍；
   口令哈希选型（`hashlib.scrypt` vs `pbkdf2_hmac`）；限时会话 token 的生成与失效。
3. 本地通道：Zig 分片进程与 Python 控制面之间仅用双方标准库可实现的受限本地通道候选
   （localhost TCP、目录投递+原子改名、命名管道），在 Windows 开发节点与 Linux 目标上
   各自的可行性、原子性与权限边界。
4. 静态前端：无构建工具链下单 HTML 文件 + 原生 ES module 的可行性与陷阱。

只记录事实与证据来源，不做架构决定；决定归 03 号及之后的票。
