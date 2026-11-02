# Hyperliquid signing and history evidence

Research UTC: **2026-11-02T05:33:15Z–05:35:29Z**. Ticket 01 input only; no adapter, credentials, signing operation, or exchange action was executed. Primary local integration reference: `D:/github/nautilus_trader/docs/integrations/hyperliquid.md`, repository HEAD `64bb2b8526fd66964125b40b5bbf0af060ed120a`, file SHA-256 `106f60f010a4def19f20ddf0fcd2c0cfe53deb1db0869562f7e1a959165fc802`. Its adapter behavior is a reference implementation, not an exchange guarantee.

## Fixed upstream source identity

Official [`hyperliquid-python-sdk`](https://github.com/hyperliquid-dex/hyperliquid-python-sdk/tree/2fdb18f9517675ea03695a0962bd19eece9c83f0), commit **`2fdb18f9517675ea03695a0962bd19eece9c83f0`**, reports package version **0.24.0**. Raw source bytes fetched at the research UTC above had these SHA-256 values:

| File at fixed commit | SHA-256 |
| --- | --- |
| [`hyperliquid/utils/signing.py`](https://github.com/hyperliquid-dex/hyperliquid-python-sdk/blob/2fdb18f9517675ea03695a0962bd19eece9c83f0/hyperliquid/utils/signing.py) | `938ec0a1f9611874b423ca946696e19a71d32d14709f521ea5d526f4398c0b85` |
| [`hyperliquid/info.py`](https://github.com/hyperliquid-dex/hyperliquid-python-sdk/blob/2fdb18f9517675ea03695a0962bd19eece9c83f0/hyperliquid/info.py) | `fc36d225a2b865d474e5682ad4f095d9917e84ef5dba9c80de3d4600467f4882` |
| [`tests/signing_test.py`](https://github.com/hyperliquid-dex/hyperliquid-python-sdk/blob/2fdb18f9517675ea03695a0962bd19eece9c83f0/tests/signing_test.py) | `ea0d7b2e9e2a224b55e05b6d1abbcc727ce1f38e72572e607a4a7045bc01a042` |
| [`hyperliquid/utils/types.py`](https://github.com/hyperliquid-dex/hyperliquid-python-sdk/blob/2fdb18f9517675ea03695a0962bd19eece9c83f0/hyperliquid/utils/types.py) | `5161dfcfc5ea39f1540d4e68ffd79520b9f5ab7aff9ce88a8440d6e6dabb88ba` |
| [`pyproject.toml`](https://github.com/hyperliquid-dex/hyperliquid-python-sdk/blob/2fdb18f9517675ea03695a0962bd19eece9c83f0/pyproject.toml) | `9503682e2a210752f6be164f7377755692c0f457476b8f4bfffc2c43700a3d33` |

Downloads were inspected under ignored `.scratch/build/hyperliquid-01-research/`. The test-source hash identifies the original upstream bytes; the retained local test excerpt contains only the public action-hash test, with all signing tests/key literals/signatures excluded. It will therefore have a different file hash. SDK source dependencies are `msgpack ^1.0.5`, `eth-account >=0.10.0,<0.14.0`, and `eth-utils >=2.1.0,<6.0.0`; the commit fixes SDK code, not a dependency resolution.

GitBook pages below were read through the web tool at research time. Direct Markdown downloads returned HTTP 403; no raw page-byte SHA-256 is claimed for them. Their URLs and access UTC identify mutable documentary evidence.

## L1 action encoding and public hash vector

Pinned SDK [`action_hash`, `construct_phantom_agent`, `l1_payload`, `sign_l1_action`](https://github.com/hyperliquid-dex/hyperliquid-python-sdk/blob/2fdb18f9517675ea03695a0962bd19eece9c83f0/hyperliquid/utils/signing.py#L161-L227) establishes:

- Hash preimage: MessagePack action bytes, nonce as eight big-endian bytes, then absent-vault byte `00` or present-vault byte `01` plus address bytes. If expiry exists, append `00` plus expiry as eight big-endian bytes. Apply Ethereum Keccak-256, not SHA3-256.
- The SDK serializes the constructed dictionary directly, so insertion order and value types form part of the hash contract. Do not sort action keys or serialize JSON as the signed payload.
- Phantom Agent uses `connectionId = action_hash`, `source = "a"` on mainnet and `"b"` on testnet. EIP-712 domain: `name=Exchange`, `version=1`, `chainId=1337`, zero verifying contract; primary type `Agent`, fields `source:string`, `connectionId:bytes32`. Environment separation occurs in this typed message.
- Order wire key order is `a,b,p,s,r,t`, optional `c`; action key order is `type,orders,grouping`, optional builder. Prices and sizes are decimal strings. Omit absent cloid rather than encode null. User-signed administrative actions use a different domain; do not reuse that path for L1 orders.

The public [`test_phantom_agent_creation_matches_production`](https://github.com/hyperliquid-dex/hyperliquid-python-sdk/blob/2fdb18f9517675ea03695a0962bd19eece9c83f0/tests/signing_test.py#L21-L35) has no key or signature. Its exact ordered action is:

```json
{"type":"order","orders":[{"a":4,"b":true,"p":"1670.1","s":"0.0147","r":false,"t":{"limit":{"tif":"Ioc"}}}],"grouping":"na"}
```

Nonce `1677777606040`; no vault; no expiry. Expected action hash / phantom `connectionId`:

```text
0x0fcbeda5ae3c4950a548021552a4fea2226858c4453571bf3f24ba017eac2908
```

This is an upstream asserted hash vector, not an independently run signer test. Ticket 03 must verify MessagePack bytes, vault/expiry variants, EIP-712 digest, and recovered signer with non-secret offline fixtures. No sendable signature is recorded here.

## Nonce and query identity

官方 [Nonces and API wallets](https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/api/nonces-and-api-wallets) 明确：nonce 按 signer 共享，包括同一 agent 为多个 vault/subaccount 签名；保存最高 100 个 nonce，新值必须未用过且大于集合最小值，处于区块毫秒时间 `(T−2 days,T+1 day)`。推荐原子递增并向当前毫秒前推。Agent 状态删除后旧 nonce 可能被剪枝，旧签名可能重放，因此不复用注销 agent 地址。查询使用实际 master/subaccount 地址，agent 地址只用于签名。重启时仅重置内存计数器不能证明 nonce 唯一；超时也不能证明订单未落地。

## History, pagination, missing order

以下上限和状态来自官方 [Info endpoint](https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/api/info-endpoint)，专属接口上限优先于通用分页说明。

| Request | Contract |
| --- | --- |
| `userFills` | 最近最多 2,000 条。 |
| `userFillsByTime` | 每响应最多 2,000，仅可访问最近 10,000；起止毫秒时间包含边界。 |
| `historicalOrders` | 最近最多 2,000；文档及固定 SDK 无时间/游标参数。 |
| 时间范围通用分页 | 500 elements 或 distinct blocks；下一页 startTime 使用末条时间。 |
| `orderStatus` | oid 接受 u64 或 16-byte cloid；缺失响应 `unknownOid`。 |

完整状态原文枚举：

```text
open filled canceled triggered rejected
marginCanceled vaultWithdrawalCanceled openInterestCapCanceled selfTradeCanceled
reduceOnlyCanceled siblingFilledCanceled delistedCanceled liquidatedCanceled scheduledCancel
tickRejected minTradeNtlRejected perpMarginRejected reduceOnlyRejected badAloPxRejected
iocCancelRejected badTriggerPxRejected marketOrderNoLiquidityRejected
positionIncreaseAtOpenInterestCapRejected positionFlipAtOpenInterestCapRejected
tooAggressiveAtOpenInterestCapRejected openInterestIncreaseRejected
insufficientSpotBalanceRejected oracleRejected perpMaxPositionRejected
```

RingWin 推论：分页须去重、检测游标不前进，不能简单 `lastTime+1` 跳过同毫秒尾项；达到上限不能宣称完整。文档没有提供同时间饱和页的额外游标。`unknownOid` 仅表示查无订单，不证明 rejected/canceled/never accepted；`triggered` 也不能直接推断经济成交。未知未来状态应保留 raw evidence 并使恢复不完整。

## Funding, liquidation, and ADL

官方 [Perpetuals info endpoint](https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/api/info-endpoint/perpetuals#retrieve-a-users-funding-history-or-non-funding-ledger-updates) 为 `userFunding` / `userNonFundingLedgerUpdates` 定义 user、inclusive startTime/endTime。Funding history row 包含 `time,hash,delta`；delta 示例为 `type=funding,coin,fundingRate,szi,usdc,nSamples`。保留 decimal 字符串和原始证据，不能由 funding rate 单独推导已结算现金。

官方 [WebSocket subscriptions](https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/api/websocket/subscriptions) 的相关字段：

| Message | Fields and distinction |
| --- | --- |
| `WsUserFunding` | `time,coin,usdc,szi,fundingRate`。 |
| `WsLiquidation` | `lid,liquidator,liquidated_user,liquidated_ntl_pos,liquidated_account_value`。 |
| `WsFill.liquidation?` | `liquidatedUser?`, `markPx:number`, `method:"market"|"backstop"`；不是整个账户清算事件。 |
| `WsFill` | `coin,px,sz,side,time,startPosition,dir,closedPnl,hash,oid,crossed,fee,tid,feeToken,builderFee?`；fee 负数为 rebate，builderFee 已包含于 fee。 |
| Snapshot | user fills/fundings 首批 `isSnapshot:true`，与后续流共享去重语义。 |

该官方 schema 将 `dir` 定义为前端显示字符串，并未给出 ADL 枚举。Nautilus 本地文档 1555–1578 行识别 `dir="Auto-Deleveraging"`、可能没有 liquidation 对象；这属于参考实现证据，不能提升为官方稳定枚举合同。官方 [Auto-deleveraging](https://hyperliquid.gitbook.io/hyperliquid-docs/trading/auto-deleveraging) 描述亏空触发对手盈利仓位按前一 mark 平仓，且 backstop 仓位在 ADL 队列中无特殊待遇。因此不能把 `backstop` 与全部 ADL 画等号，也不能把 liquidation 汇总事件当作第二笔 Fill。

## Explicit remaining evidence

- Ticket 03: independently execute the public hash vector and verify byte, digest, recovery and nonce restart boundaries; no signature implementation was attempted here.
- Ticket 05/06: preserve historical cap and same-timestamp ambiguity as incomplete recovery; establish stable economic identities for funding/liquidation before applying account changes. Official WS schema does not promise `tid` alone is globally unique.
- Ticket 07: obtain redacted testnet evidence for ADL direction and liquidation/ledger correlation, or mark those observations unavailable; do not fabricate a venue guarantee from the Nautilus reference.

No live API account query, testnet trading, real key access, or production qualification was performed. Documentary contracts and the upstream hash expectation do not establish end-to-end acceptance.
