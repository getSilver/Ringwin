# 08 保留原生 Demo 账户前后验安全门

Type: task
Status: in-progress
Assignee: Codex native account guard implementer
Blocked by: [04 保护认证与传输](04-protect-auth-and-transport-copies.md)
Parent: [凭证安全修复](../map.md)

## Question

移除 managed EnvFile preflight 后，如何保持原账户前后验合同，避免凭证修复削弱业务安全门？

## Acceptance criteria

- [ ] 新增原生只读 guard，复用05传入的受保护 transport source；只GET并断言元数据，不产生 CanonicalEvent，不新增控制面或生产准入。
- [ ] 固定旧 `tools/okx-demo-preflight.ps1` 判断：server time偏差至多5s；真实UID hash比对；Read+Trade、无Withdraw、acctLv2/net_mode/禁借贷；SPOT/SWAP唯一允许且live/post_only；isolated/net leverage存在。
- [ ] positions、普通pending orders、全部7种algo pending为零；全量与BTC/USDT balance三类liability为零，funded currency仅USDT（显式allow_btc仅供既有清理合同，不能隐式授交易）。
- [ ] 缺字段、非成功响应、异常JSON/数值、身份不符均拒绝；decimal zero用严格十进制判断，避免float下溢把非零债务/仓位当0。
- [ ] 已授权auth/transport公共合成seam验证正常与各拒绝类别，无真实网络/凭证。只新增guard及测试/证据，05拥有实际调用点与脚本；父级05在正常/失败后验和首次写前完整接入后才可关闭。
- [ ] 保留红绿日志与源码、命令、编译器、产物身份；Windows/Linux定向，不跑全量。

## Answer

接口与05约定：`run(allocator, source:anytype, local_ms:i64, expected_uid_hash:[]const u8, allow_btc:bool)!void`；`source.get(path)![]const u8` 借用响应只到下次get，guard必须及时解析。仅GET接口不具有订单写能力。05负责实际source的timestamp刷新、调用与生命周期/失败后验。

首个公共正常路径回归：先`NotImplemented`红，随后Windows Debug1/1绿；独立合成source记录16个精确GET路径（含全部7algo和两份balance），响应复用同一buffer以检验借用寿命，每次解析在下次get前释放。UID预期SHA由独立Python hashlib固定literal给出，不拿实现自算结果当断言。证据`runs/08-normal-red-v1`、`runs/08-normal-green-v1`。当前模块正常路径已实现，逐类拒绝与Linux定向待补；05接入仍独立待办。
