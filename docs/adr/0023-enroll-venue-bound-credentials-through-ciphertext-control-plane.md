---
status: accepted
date: 2026-11-06
---

# 控制面只接收绑定交易所的加密凭证包

SystemOwner 在原生程序中以隐藏输入录入交易所秘密和独立加密口令，复用 CredentialStore 的
Argon2id、XChaCha20-Poly1305 和受保护内存。现有 Web 控制面通过 OwnerSession 与 CSRF 接收
加密包；它不接收 API Key、私钥或解锁口令。浏览器直接录入明文会让 Python、代理与浏览器
承担新的秘密内存生命周期，因此采用加密包导入。

CRD4 v2 在认证头中增加 Venue。凭证按 Venue、ExchangeAccount、Environment、credential_id
和 version 分目录，目录内继续分 observation/execution 文件；旧版本的吊销记录不被新录入
覆盖。CRD4 v1 保留原有专用路径兼容性，不从旧文件推断 Venue，也不允许上传为新绑定凭证。
导入 Web 收件箱仅代表收到密文，头部信息在 AEAD 验证前均不可信。节点原生导入必须解锁、
认证、校验用途与材料类型，再以 Staged 原子注册；激活与 EnableTrading 仍是独立操作。

此决定扩展 ADR 0005 的只读范围：API Credential 可以创建 Gateway 所有的受保护会话，使用时
核对文件身份、有效期和当前 fencing；观察会话不能用于新增风险。OKX、Binance、Bybit 的认证
入口复用该会话；Hyperliquid 继续使用已有的受控钱包签名、持久 nonce 与 fencing 路径。
旧 `admitExecution` 仍拒绝，避免旧调用方因本次扩展获得发送能力。公共行情及 Hyperliquid
只读账户查询不需要私钥，不为它们伪造 ObservationCredential。

凭证生命周期的人工入口仍为现有控制面 `/lifecycle` 与 RiskWarning；原生程序是节点侧秘密
录入/解锁及持久化原语，不是第二套远程控制面。生命周期 outbox 的入队回执不是节点应用回执；
部署必须将已验签请求交给对应节点，并独立验证绑定与执行回执。本次离线证明不提升生产资格。
