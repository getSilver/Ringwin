# 研究成果：Python 标准库控制面技术基础

- 对应研究票：../issues/02-research-python-stdlib-foundations.md
- 日期：2026-08-23
- 范围：只记录事实、证据来源与候选对比，不做架构决定（决定归 03 号及之后的票）。
- 方法：关键论断以官方一手文档核实（Python 官方文档、RFC、MDN、Zig 源码仓库 / Microsoft Win32 文档）。检索日期即本文日期；引用版本为 Python 3.14 文档与 Zig master 分支，落地时需按实际锁定版本复核。
- 上游语义参考：CONTEXT.md 中 ControlCommand、OwnerSession、RiskWarning。

---

## 1. Web 层：http.server 承载单页 UI + JSON API

### 事实

- http.server 官方文档明确警告：not recommended for production，只实现 basic security checks。
- ThreadingHTTPServer = HTTPServer + ThreadingMixIn（每请求一线程）；其存在动机之一正是处理浏览器预开连接导致单线程 HTTPServer 无限等待。Python 3.14 新增 HTTPSServer / ThreadingHTTPSServer，可用 ssl 包 TLS。
- BaseHTTPRequestHandler.protocol_version 默认 HTTP/1.0；设为 HTTP/1.1 以获得持久连接时，服务器必须为每个响应给出准确 Content-Length 头。推论：
  - 普通 JSON API：给出 Content-Length 即可正常持久连接；
  - 流式响应（SSE）：无法预知长度，需手动实现 chunked transfer-encoding 分帧写 wfile，或用 Connection: close 定界。
- 已知陷阱（文档 Security considerations 一节）：
  - SimpleHTTPRequestHandler 跟随符号链接，可能暴露指定目录之外的文件；
  - send_header() / send_response_only() 不做 CRLF 校验，不可信输入可造成 HTTP 头注入；
  - 旧版 stderr 日志未清洗控制字符（3.12 起已清洗）。自写 handler 时响应头值必须自行消毒。
- SimpleHTTPRequestHandler 支持 directory= 限定服务根目录、If-Modified-Since 协商缓存、extensions_map/mimetypes 推断 MIME（.js 可正确映射 JavaScript MIME 类型）。CGIHTTPRequestHandler 已废弃（3.13 起，3.15 移除）。
- WebSocket：Python 标准库不含任何 WebSocket 实现（模块索引无 websocket 模块；http.server 无 Upgrade 处理路径）。纯标准库下 WebSocket 不可行。

### 标准库内 UI 数据刷新的可行路径对比

| 候选 | 标准库支持情况 | 关键约束 |
|---|---|---|
| 客户端轮询 | 完全可行：浏览器 fetch() 定时 GET JSON 端点 | 最简最鲁棒；刷新延迟 = 轮询间隔 |
| 手写 SSE | 可行但服务端全手工：EventSource 为浏览器原生 API；do_GET 发 Content-Type: text/event-stream 后持续写 data 帧定界见上 | 非 HTTP/2 下每浏览器+域名约 6 条并发连接（MDN）；断线自动重连（retry 字段）；流须 UTF-8；注释行可作 keep-alive |
| 长轮询 | 可行：handler 线程内阻塞等待事件再返回 | 占住一个线程直到事件或超时 |
| WebSocket | 标准库不可行 | 务实替代即上三者，SSE 是唯一纯标准库推送通道 |

### 证据

- https://docs.python.org/3/library/http.server.html （production 警告、ThreadingHTTPServer、protocol_version 与 Content-Length 约束、Security considerations）
- https://developer.mozilla.org/en-US/docs/Web/API/Server-sent_events/Using_server-sent_events
- https://docs.python.org/3/library/socketserver.html
- 标准库模块索引（WebSocket 缺失的否定性事实）：https://docs.python.org/3/library/index.html

### 对本项目的含义

- 单用户（OwnerSession）、本地/管理网访问的 Operator UI 吞吐远低于能力边界；not-for-production 警告针对公网多租户通用安全面，本项目需以自身认证层 + 绑定地址收敛补偿，如何补偿归后续票决定。
- 推送式刷新只有 SSE 一条纯标准库路径，代价是手写分帧 + HTTP/1.1 连接数限制；轮询是零风险基线。
- 无论选哪条路都必须自建路由分发、JSON 编解码（json 模块）、头消毒与错误处理——BaseHTTPRequestHandler 只提供解析骨架。

---

## 2. 认证：TOTP、口令哈希与会话 token

### 事实 — RFC 6238 TOTP

- TOTP = HOTP(K, T)，T = floor((当前 Unix 时间 - T0) / X)；默认 X=30 秒、T0=0。允许 HMAC-SHA1/SHA256/SHA512；密钥应随机生成且长度等于 HMAC 输出。
- 时钟窗口取舍（RFC 5.2 节）：验证方除接收时刻外还应比较传输延迟窗口内的过去时间步；RFC 建议最多允许 1 个时间步的网络延迟窗口；窗口越大攻击面越大。默认步长 30 秒是安全与可用的平衡。
- 重放防护（RFC 5.2 节）：同一时间步内同一 OTP 可能被多次提交，验证系统 MUST NOT 在该 OTP 成功验证后再次接受——成功后必须记录已消费的时间步。
- 再同步（RFC 第 6 节）：限制 prover 可失步的时间步数（前后双向），成功验证时记录检测到的时钟漂移用于后续校正；长期漂移超阈值需额外认证显式重同步。
- 用 hmac/hashlib/secrets 实现要点：HMAC over 8 字节大端计数器，动态截断（末字节低 4 位为偏移，取 4 字节屏蔽最高位，mod 10^位数）。RFC 附录 B 给出跨实现测试向量（secret 为 ASCII "12345678901234567890"、T=59s、SHA1 得 94287082），可直接用作自实现对拍测试。
- 验证码比较必须用常量时间比较：hmac.compare_digest() / secrets.compare_digest()。

### 事实 — 口令哈希

- hashlib.scrypt(password, *, salt, n, r, p, maxmem=0, dklen=64)：scrypt（RFC 7914）绑定；n 为 CPU/内存成本因子；OpenSSL 默认 maxmem 约 32 MiB，参数过大会抛错，需显式调 maxmem。
- hashlib.pbkdf2_hmac(hash_name, password, salt, iterations, dklen=None)：PBKDF2-HMAC；文档建议盐至少约 16 字节取自 os.urandom()；截至 2022 年建议 SHA-256 数十万次迭代；3.12 起仅 OpenSSL 构建提供（纯 Python 慢速实现已删除）。
- 选型事实（非决定）：scrypt 为内存困难型，抗 GPU/ASIC 更强但对参数与 maxmem 敏感；pbkdf2_hmac 参数简单、行为可预测，有 NIST SP 800-132 背书。两者均为标准库内受支持原语。
- secrets 文档明确：口令不得以可恢复格式存储，应加盐后经强单向哈希处理。

### 事实 — 限时会话 token

- secrets.token_urlsafe/token_hex/token_bytes：默认 DEFAULT_ENTROPY；官方认为 32 字节（256 位）随机性对典型用途足够。
- 生成来源为操作系统最高质量随机源（SystemRandom / os.urandom）。
- 失效模式能力边界：标准库无会话框架。可行做法：(a) 服务端集合存 token + 过期时间戳，验证查存在性与过期，可即时吊销；(b) 自包含 HMAC token（hmac + 过期时间字段 + compare_digest），无需服务端存储但不能单独即时吊销。取舍归后续票。

### 证据

- https://datatracker.ietf.org/doc/html/rfc6238 （X/T0 默认值、5.2 节窗口与 MUST NOT 重放、第 6 节再同步、附录 B 测试向量）
- https://docs.python.org/3/library/hashlib.html
- https://docs.python.org/3/library/secrets.html
- https://docs.python.org/3/library/hmac.html （compare_digest）

### 对本项目的含义

- RFC 6238 可在 hmac/hashlib/secrets 上以约几十行实现，且有官方测试向量兜底；OwnerSession 词条要求的主认证 + TOTP 与之直接对应。
- 窗口与重放记录是必须显式设计的两点：±1 步窗口 + 已消费时间步记录是 RFC 推荐组合。
- 会话失效需自建；对照 CONTEXT.md：OwnerSession 是限时会话、ControlCommand 有有效期限——token 方案必须能表达两类期限语义。

---

## 3. 本地通道：Zig 进程与 Python 进程之间的受限通道候选

### 事实 — 候选 A：localhost TCP

- Python socket 跨平台提供 TCP；multiprocessing.connection.Listener/Client 原生支持 AF_INET，内置基于 HMAC 的 authkey 挑战应答认证（密钥不在线传输）。
- 文档注意点：Listener 绑 "0.0.0.0" 在 Windows 上不是可连接端点，应绑 "127.0.0.1"。
- Zig 侧：std.net 提供 TCP listen/accept/connect（lib/std/net.zig，Windows 经 ws2_32），双方标准库零依赖互通。
- 权限边界：localhost TCP 对本机所有进程可达；隔离只能靠应用层认证 + 绑定 127.0.0.1，无 OS 级 ACL。
- 原子性：TCP 字节流无消息边界，需自定帧协议（长度前缀等）；不能依赖 send 的隐式原子性。

### 事实 — 候选 B：目录投递 + 原子改名写入

- os.replace(src, dst)：目标为文件时静默替换；跨文件系统失败；文档写明 If successful, the renaming will be an atomic operation (this is a POSIX requirement)——POSIX 上原子性是文档化契约。
- os.rename 在 Windows 上目标存在时总抛 FileExistsError；跨平台覆盖必须用 replace。
- Windows 补充事实：CPython 经 Win32 MoveFileEx 类调用实现；同卷改名实践上是元数据级原子替换，但 Microsoft 未对 MoveFileEx 给出显式原子性契约，且目标被其他进程打开时可能得到 sharing violation / PermissionError，读侧需容忍瞬时失败重试。写方按 写临时名 - fsync - rename 模式时，POSIX 读方只会看到旧文件或新文件之一。
- Zig 侧：std.fs 提供 rename 等（Linux rename(2)/renameat2，Windows 相应 NT/Win32 路径）；双侧均可做到同目录原子改名。
- 权限边界：继承目录所在文件系统权限模型（POSIX uid/gid/mode；Windows ACL）。
- 原子性边界：单文件投递原子；多文件消费顺序、通知机制（标准库无 inotify 等价抽象，Python 需轮询扫描）需自行设计。

### 事实 — 候选 C：命名管道

- Python 标准库对命名管道的支持：
  - POSIX：os.mkfifo() 创建 FIFO（Unix only）。
  - Windows：标准库唯一命名管道高层接口是 multiprocessing.connection（family=AF_PIPE，地址形如 \\.\pipe\PipeName）；Listener/Client 封装 Windows named pipe，支持 HMAC authkey 与 wait() 多路等待。
  - 该接口消息层用 pickle 序列化，文档明确警告从不可信源 unpickle 是安全风险；跨语言场景只能用 send_bytes/recv_bytes 字节级接口。
- Windows 上 Python 无法用 socket/os API 直接创建命名管道服务端（CreateNamedPipeW 无 os 层暴露）。
- Zig 侧成本：
  - std.os.windows 暴露 extern 绑定 CreateNamedPipeW 及匿名管道包装 CreatePipe（基于 NtCreateNamedPipeFile/NtCreateFile）；
  - 官方 issue #19047 明确表态 Zig 不打算提供未内部使用的 Win32 绑定——命名管道服务端所需 ConnectNamedPipe、实例管理等需项目自带 FFI 绑定或借助 zigwin32；std 无跨平台命名管道抽象。
- 客户端侧成本低：Windows 任意进程可用 CreateFile 打开 \\.\pipe\name；Python 侧 Client() 直连。
- 权限边界：Windows 由 CreateNamedPipe 的 SECURITY_ATTRIBUTES 决定 DACL，默认仅本机；POSIX FIFO 走文件系统权限位。
- Linux 目标：FIFO 双方均易实现；但 Unix domain socket 通常更优——Python multiprocessing.connection AF_UNIX 原生、Zig std.net AF_UNIX 原生，一并记录为第四候选。

### 候选对比汇总（事实层面）

| 候选 | Windows 开发节点 | Linux 目标 | 原子性 | 权限边界 | 双侧标准库成本 |
|---|---|---|---|---|---|
| localhost TCP | 可行（127.0.0.1 + HMAC 认证） | 可行 | 流式无边界，需自定帧协议 | 仅应用层认证 | 低 |
| 目录投递 + os.replace | 可行；目标被打开时可能瞬时失败需重试；原子性非文档契约 | 可行；rename 原子性为 POSIX 文档契约 | 单文件投递原子 | 文件系统权限模型 | 低-中（通知/顺序自设计） |
| 命名管道 | Python 仅经 multiprocessing.connection（pickle 风险，须 bytes API）；Zig 服务端需自带 Win32 绑定 | FIFO 可行但生态偏弱 | 管道字节流，同 TCP 需帧协议 | Windows DACL / POSIX mode 位 | 高 |
| Unix domain socket（仅 Linux） | 不可用 | Python AF_UNIX 与 Zig std.net 原生支持 | 流式需帧协议；dgram/seqpacket 可选 | 文件系统权限 | 低 |

### 证据

- https://docs.python.org/3/library/os.html （os.replace/os.rename 平台行为与 POSIX 原子性条款）
- https://docs.python.org/3/library/multiprocessing.html （Listeners and Clients：AF_INET/AF_UNIX/AF_PIPE 地址格式、authkey HMAC 认证、wait()、0.0.0.0 Windows 注意事项、unpickle 安全警告）
- https://learn.microsoft.com/en-us/windows/win32/api/namedpipeapi/nf-namedpipeapi-createnamedpipew （语义、DACL、\\.\pipe\LOCAL\ 限制）
- https://github.com/ziglang/zig/blob/master/lib/std/os/windows/kernel32.zig （CreateNamedPipeW extern 绑定）
- https://github.com/ziglang/zig/issues/19047 （Zig 不提供未内部使用的 Win32 绑定的官方立场）

### 对本项目的含义

- 三个候选在双方标准库内都可行；差异集中在：Windows 原子性契约强度（TCP/管道流式 vs rename 实践原子 vs POSIX 文档契约）、Zig 侧对接成本（命名管道明显最贵）、权限边界（文件系统 > 命名管道 DACL > localhost TCP 仅应用层）。
- 对照 CONTEXT.md 的 StrategyHostControlChannel / HostSupervisor 词条：控制面通道只承载有界版本化帧，任何候选都需要自定帧协议与认证层；目录投递天然提供"单消息原子可见"语义，TCP/管道需要帧 + 校验自行达到同等保证。选型归后续票。

---

## 4. 静态前端：无构建工具链下单 HTML + 原生 ES module

### 事实

- 所有现代浏览器原生支持 ES module，无需转译（MDN：All modern browsers support module features natively without needing transpilation）。入口写法 script type="module" src=... 或内联 module 脚本。
- import 必须使用可解析为 URL 的模块说明符（相对/绝对路径或完整 URL），且必须带 .js 扩展名；裸模块名需 import map（script type="importmap" 内联 JSON）。
- 常见陷阱：
  - file:// 协议下加载 ES module 会因 CORS 安全要求报错——必须经 HTTP 服务器测试（MDN 明示）。
  - 模块脚本必须以含 JavaScript MIME 类型（如 text/javascript）的 Content-Type 提供，否则浏览器拒绝执行并报 strict MIME checking 错误。
  - module 自动严格模式、自动 defer、仅执行一次；导入绑定是只读视图。
  - 动态 import() 可用于按需加载；top-level await 仅在 module 中可用。
  - JSON/CSS 等非 JS 资源需 import attributes（with { type: "json" }）。
- fetch 同源 GET JSON 无 CORS 问题；同源前提下轮询/SSE 均可直接用。
- 单 HTML 文件方案事实：内联 module 脚本可以工作，但内联模块无法被其他模块 import（没有 URL）；若代码量增长，拆成少量静态 .js 文件由 http.server 直接服务同样零构建。

### 证据

- https://developer.mozilla.org/en-US/docs/Web/JavaScript/Guide/Modules （原生支持声明、type="module"、import map、file:// CORS 错误、MIME 类型要求、module 与 classic script 差异、动态 import、import attributes）

### 对本项目的含义

- 零构建单页 UI 技术上完全成立：http.server 提供正确 MIME 的静态文件 + 同源 JSON API，前端用原生 ES module + fetch。
- 主要约束是把 UI 保持在一个 HTTP 源下（避免 CORS），以及接受无打包带来的代码组织自律（相对路径带扩展名、无 npm 依赖）。

---

## 附：未决问题清单（供后续 grilling 票参考，本文不决定）

1. Web 层刷新机制（轮询 vs SSE）与 http.server 生产化补偿措施（绑定地址、TLS、反代理）。
2. TOTP 窗口参数、口令哈希算法选择与会话 token 形态（服务端状态型 vs 自包含 HMAC 型）。
3. 本地通道候选取舍及帧协议设计（含 Unix domain socket 是否纳入 Windows 缺席的权衡）。
4. 单 HTML 内联 vs 少量静态 .js 文件的代码组织边界。
