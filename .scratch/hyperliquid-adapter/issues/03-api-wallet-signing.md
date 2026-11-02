# 03：Hyperliquid API 钱包凭证与签名

Type: task
Status: open
Assignee:
Blocked by: [01 协议与字段合同](01-protocol-field-contract.md)
Parent: [模块地图](../map.md)

## Question

如何用获授权的 API 钱包为真实资金账户签名，并使秘密、nonce 与主备切换服从既有安全生命周期？

## What to build

API 钱包即 Hyperliquid agent wallet，与 AI Agent 无关。复用 CredentialStore、GatewayLease、session 和 fencing；通用秘密表示归 `src/security/`，Venue 签名与协议编码归 `src/adapters/hyperliquid/`。

## 完成条件

- [ ] 明确私钥、签名钱包地址与资金账户地址的不同职责；查询/订阅使用显式资金账户，不回退到 agent 地址；环境、账户或凭证变更产生新 session。
- [ ] 凭证类型准确表示私钥，不以虚假 api_key/passphrase 填充旧三元组；列明凭证编码版本及既有凭证兼容处理。
- [ ] 私钥只经现有受限安全能力使用，保留加密、受保护内存、清零与撤销处理；不进入策略、日志、RawIngress、普通配置或 fixture。
- [ ] 通过可追溯的合成/官方向量验证签名、序列化、网络域及账户绑定；错误私钥/地址/环境在发送前拒绝。
- [ ] 明确 nonce 唯一性与时效、时钟回退、重启、主备切换和共享 signer 竞争的处理；旧 owner/session 不能签发可发送请求。
- [ ] 证明结果 Unknown 时不能因新 nonce 重发；钱包授权不等于 Ringwin 交易授权。
- [ ] 默认离线测试不读取真实凭证；既有凭证与权限回归通过，平台秘密内存未验证项明确保留。

## Answer

尚未开始。本票不创建或授权真实钱包，不提供资金划转或 vault 能力。
