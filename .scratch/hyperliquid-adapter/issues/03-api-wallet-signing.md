# 03：Hyperliquid API 钱包凭证与签名

Type: task
Status: resolved
Assignee: Codex
Blocked by: [01 协议与字段合同](01-protocol-field-contract.md)
Parent: [模块地图](../map.md)

## Question

如何用获授权的 API 钱包为真实资金账户签名，并使秘密、nonce 与主备切换服从既有安全生命周期？

## What to build

API 钱包即 Hyperliquid agent wallet，与 AI Agent 无关。复用 CredentialStore、GatewayLease、session 和 fencing；通用秘密表示归 `src/security/`，Venue 签名与协议编码归 `src/adapters/hyperliquid/`。

## 完成条件

- [x] 明确私钥、签名钱包地址与资金账户地址的不同职责；查询/订阅使用显式资金账户，不回退到 agent 地址；环境、账户或凭证变更产生新 session。
- [x] 凭证类型准确表示私钥，不以虚假 api_key/passphrase 填充旧三元组；列明凭证编码版本及既有凭证兼容处理。
- [x] 私钥只经现有受限安全能力使用，保留加密、受保护内存、清零与撤销处理；不进入策略、日志、RawIngress、普通配置或 fixture。
- [x] 通过可追溯的合成/官方向量验证签名、序列化、网络域及账户绑定；错误私钥/地址/环境在发送前拒绝。
- [x] 明确 nonce 唯一性与时效、时钟回退、重启、主备切换和共享 signer 竞争的处理；旧 owner/session 不能签发可发送请求。
- [x] 证明结果 Unknown 时不能因新 nonce 重发；钱包授权不等于 Ringwin 交易授权。
- [x] 默认离线测试不读取真实凭证；既有凭证与权限回归通过，平台秘密内存未验证项明确保留。

## Answer

已完成离线实现与审查；未创建或授权真实钱包，不提供资金划转或 vault 能力。

- 安全凭证改为 API 三元组 / API 钱包 tagged union；钱包 payload v2，CRD4 envelope/v1 三元组兼容不变。私钥原位解码到受保护目标，签名地址由私钥校验，资金地址单独绑定。
- `CredentialStore.signWallet` 强制 session、GatewayLeaseGuard、账户和当前 owner 校验；受限输入、解密、nonce 持久消费、签名和最终复查在现有 writer 锁内完成。digest 回调只获得 nonce，不获得 lease 或私钥；没有公开的 lease 裸签名入口，也没有新交易授权入口。
- RFC6979、HMAC、SHA-256 schedule、私钥 scalar、nonce 与工作点使用受保护 workspace，所有退出路径清零；复用现有 protected_memory 和 hardened SHA-256。固定 SDK 的 MessagePack、网络域、subaccount/expiry digest、签名 hash 与恢复地址离线对齐。
- SN01 ledger 按 signer 保存高水位及原始 dispatch identity，先同步后签名；重启/换 owner/Unknown 不释放已消费身份。锁竞争、损坏/缺失/torn tail、大幅时钟回退失败关闭。满 65,536 条拒绝继续，未宣称持续高吞吐资格。
- [实现、版本与部署边界](../../../docs/research/2026-11-02-hyperliquid-wallet-signing.md)；[独立向量 oracle](../../../python/hyperliquid_signing_vectors.py)。同一 signer 仅支持同一受保护 store/稳定锁；跨机独立副本不协调，旧 ledger 回滚或重建无效。后续 05/07 保留原 Gateway dispatch identity、Unknown 和发送前权限检查。

### 验证与审查

- 固定 Zig `0.17.0-dev.315+5b647b792`，Windows，全部离线，未读取真实凭证。
- 独立 Python oracle：3 组固定 SDK hash/digest/recovery 向量及 RFC6979 签名 hash 通过；仅在忽略的临时 venv 安装校验依赖。
- 审查前 Debug / ReleaseSafe 定向各 55/55；修复后 ReleaseSafe 定向 56/56，新增签名 workspace 成功/锁失败时的释放前清零观察。最终 Debug 定向 56/56；最新公开安全入口 lease 中途失效与请求消费的 ReleaseSafe 回归 2/2。
- 最终新增边界用例后 ReleaseSafe 定向 **57/57**；零 digest / 最大合法私钥与最大 digest 的独立 oracle 同步通过。
- 初次 Debug 全量测试在超过 20 分钟后主动停止，以验证审查修复后的最终代码；未取得那次全量通过结论。最终 `zig build test -Doptimize=ReleaseSafe` 的 wrapper 返回 0，但 listen 模式日志含 `failed command` 字样，不单独以此声称全量全绿。直接运行同一完整 ReleaseSafe 测试二进制（无 `--listen`）：**834/834 全部通过，退出 0**。
- 完整二进制 `.zig-cache/o/d57dbac5550346d8638f93502b016d59/test.exe`，SHA-256 `8768b6527445fdbbb28bd4bba524b5cd31343c52e904e0cd2a01971ef941eac6`。它编译于最后新增边界 test case 之前；生产实现相同，新增用例与最终公开入口断言由最新 57/57 定向运行覆盖，未声称重新编译后的完整 suite 为 835/835。
- 详细日志位于忽略的 `.scratch/build/hyperliquid-03-final-debug.log`、`hyperliquid-03-final-targeted.log`、`hyperliquid-03-final-full.log` 和 `hyperliquid-03-full-diagnostic.log`。

#### Standards

两次审查无阻塞项；安全凭证、nonce 存储和 Venue 协议职责分开，复用既有受保护内存与 SHA-256。初次重复元数据校验仅属可选观察，最终共享 session/校验归安全模块。

#### Spec

初次发现两个阻塞项：公开 lease 签名可绕过 nonce/fencing；stdlib ECDSA 显式私钥副本未纳入清零。已改为不可绕过的 `CredentialStore.signWallet` 与受保护 RFC6979/HMAC 工作区，并把私钥解码改为原位写入；复审无新增阻塞项。

本票不授予 Testnet/Demo/主网在线交易或生产资格。字段/曲线算术的编译器栈与寄存器临时值、Linux 目标秘密内存、跨机外部 fencing 及断电持久化仍未验证，未以离线结果关闭这些平台资格。
