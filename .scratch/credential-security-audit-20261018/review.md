# 凭证保护与清零审计

2026-10-18，审计当前 `main` / `c5f73ba08ed10e6a5f42e97264f4c72e9b2f2864`。
原提交 `0bf8d96f` 的等价主线提交为 `549282ff`。比较入口为
`git diff 549282ff^...HEAD -- src/credential_store.zig src/okx_rest_auth.zig src/okx_curl_transport.zig`，
并追踪当前运行时、C shim 和固定 Zig 标准库。需求来源为 `docs/加密任务.md`、
`CONTEXT.md`、ADR0005；ADR0010 规定平台资格独立。本文是审计报告，不是新实施规格。

结论：保护页本身的正常释放顺序正确，但目前不能确认端到端凭证保护与清零完整。
以下是当前仍存的遗漏，不都由 `0bf8d96f` 引入。未修改业务源码，也未读取真实凭证或执行网络请求。

## Standards

1. **P2：KDF 的安全性依赖构建模式及普通 allocator。**
   `src/credential_store.zig:567` 将普通 allocator 交给 Argon2id。固定 Zig 的
   `lib/std/crypto/argon2.zig:496` 的 h0 和 `502` 的 19 MiB 工作区没有显式安全擦除；
   `deinit` 最终经过 `Allocator.free` 的 undefined 填充。合成探针在 ReleaseFast 下，
   用释放后的最后 1 KiB 工作区重新计算出完全相同的 KEK。
   **ReleaseSafe 本次被 allocator 的 0xaa 填充覆盖，未复现释放后恢复 KEK**，
   不能将 ReleaseFast 结果冒称当前生产 ReleaseSafe 的已复现泄漏。
   仍需安全 allocator/受保护工作区、显式擦除和取消/失败路径验证，不能依赖调试填充。

2. **P2：明文先落普通内存，之后才建立保护。**
   `src/credential_store.zig:370` 的 plaintext、`376` 的 decoded material、
   `416` 的按值参数/owned_material 均在普通内存；`429` 先复制明文，
   `434–436` 才锁页并 DONTDUMP。正常返回有清零，不消除存活期间的换页和转储窗口。
   应先建立安全分配和保护，再解密/解码进入；同时覆盖口令、KEK、KDF 工作区及中间副本。

3. **P2：Linux TTY 没有关闭口令回显。**
   `src/credential_store.zig:125–137` 仅 Windows 有关 echo 的分支；Linux 仅 isTty。
   默认 ECHO 的交互终端会显示输入口令，可能进入终端录屏/会话记录。
   应由输入函数自身管理 termios，并在正常和异常退出恢复设置。此项是源码路径确认，
   没有用真实口令进行 Linux TTY 测试。

4. **P2：HMAC 上下文仍保留可恢复 secret。**
   `src/okx_rest_auth.zig:113` 的 hmac 未清零。固定标准库 `crypto/hmac.zig` 的
   `o_key_pad` 在 final 后保留 normalized_secret XOR 0x5c。
   两种优化模式的合成探针都在 final 后直接恢复出测试 secret；对 ≤64 字节 secret 可直接逆变换。
   Credentials.deinit 擦除原字段并不能清理此副本。需清理上下文并核对库内部 scratch。

未发现需要独立报告的 Fowler smell。四项 Standards 遗漏，最高 P2；KDF 分级已按实测限定修正。

## Spec

1. **P1：撤销的相同凭证可被重新写入并激活。**
   `src/credential_store.zig:306–310` 的 stage 不检查现有状态、身份或 generation，
   `640` 替换同 kind 的固定文件。公开 API 合成探针实际执行
   stage → activate → revoke → stage(原 ID/version/generation、原 secret) → activate → admit，
   返回 ready，generation 从撤销时 3 回到激活时 2。
   违反 ADR0005 单向生命周期，以及原任务“不要覆盖旧密钥”“配置回滚也不得重新激活”。
   应拒绝原身份/版本重建，保留撤销证据；新版本的轮换须通过独立明确的授权流程。

2. **P1：Linux TTY 口令回显违反人工安全解锁要求。**
   同上 Standards 第 3 项。该项在 Spec 轴按口令可直接进入终端记录的影响列为 P1，
   与 Standards 的 P2 判断分开记录，不作为已完成目标机安全验收。

3. **P2：实际 OKX 业务通道没有使用受保护租约。**
   `src/windows_verification_runtime.zig:1396–1415` 从环境变量取得 key/secret/passphrase，
   复制到普通 auth.Credentials/TransportOwner；其长期存储没有锁页或 DONTDUMP。
   `src/credential_store.zig:332–337` 的只读准入立即释放 lease，返回的是准入摘要；
   `withReadOnlyMaterial` 没有实际网关调用。Linux production_runtime 明确尚无凭证/交易所套接字。
   ADR0005 原本只授 observation/read-only，execution admission 仍 out-of-scope；
   这是端到端保护尚未完成的范围，不能把只读组件测试宣传为生产执行密钥已安全接入。

4. **P2：传输复制没有纳入清零。**
   `src/okx_curl_shim.c:78` 用 curl_slist_append 复制含 API key/passphrase 的 headers；
   `80/101/110` 的退出路径只 free，没有擦除。Zig 的 signed.clear 无法清理这些 C 堆副本。
   `src/okx_rest_auth.zig:113` 的 HMAC 残留另见 Standards 第 4 项。
   需给请求级副本明确生命周期和清零规则，并核对 TLS/WS 库的复制边界。

四项 Spec 遗漏，最高 P1。两条审查线独立计数，存在重叠，不代表八个互不相同的根因。

## 已确认的正向行为

- Secret.deinit：恢复 RW → secureZero 整页 → unlock → free。
- unlock/writeEncrypted 正常或错误返回时，已声明的 plaintext/payload/key 有 defer 清零。
- 公开 stage 在输入失败时也会擦除 material 和 password_buffer。
- AEAD 认证 metadata、错误口令/上下文拒绝、观察与执行准入分离的现有定向检查通过。

## 验证及边界

固定工具链 `D:/Program Files/zig/zig.exe`，`0.17.0-dev.315+5b647b792`。
串行现有凭证定向检查 3/3、OKX auth 检查 1/1 通过。
最初并行运行导入同一测试模块的 root，撞上固定临时目录，产生 FileBusy/FileNotFound；
改为串行后通过，不将那次干扰登记为产品失败。

`probe.zig` 的三组探针在 ReleaseSafe/ReleaseFast 各执行一次；
它们断言当前行为，用于复现漏洞，**通过不是安全合格**。没有接触真实凭证。
复现入口 `python .scratch/credential-security-audit-20261018/run-probes.py`，
命令、日志 SHA 和源码身份见 `validation.json`、`ReleaseSafe.log`、`ReleaseFast.log`。

本次未运行全量套件、目标 Linux/Windows dump/swap/掉电资格或真实 Venue 请求。
上述文件清理、TTY、工作区和网关边界修复并补充相应故障验证前，不应宣称整个凭证链已安全闭合。
