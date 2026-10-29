# 08 保留原生 Demo 账户前后验安全门

Type: task
Status: resolved
Assignee: Codex native account guard implementer
Blocked by: [04 保护认证与传输](04-protect-auth-and-transport-copies.md)
Parent: [凭证安全修复](../map.md)

## Question

移除 managed EnvFile preflight 后，如何保持原账户前后验合同，避免凭证修复削弱业务安全门？

## Acceptance criteria

- [x] 新增原生只读 guard，复用05传入的受保护 transport source；只GET并断言元数据，不产生 CanonicalEvent，不新增控制面或生产准入。
- [x] 固定旧 `tools/okx-demo-preflight.ps1` 判断：server time偏差至多5s；真实UID hash比对；Read+Trade、无Withdraw、acctLv2/net_mode/禁借贷；SPOT/SWAP唯一允许且live/post_only；isolated/net leverage存在。
- [x] positions、普通pending orders、全部7种algo pending为零；全量与BTC/USDT balance三类liability为零，funded currency仅USDT（显式allow_btc仅供既有清理合同，不能隐式授交易）。
- [x] 缺字段、非成功响应、异常JSON/数值、身份不符均拒绝；decimal zero用严格十进制判断，避免float下溢把非零债务/仓位当0。仅三种liability字段沿用既有领域合同：显式存在的空字符串/全空白字符串表示0；missing/non-string仍拒绝，pos/eq不接受此例外。
- [x] 已授权auth/transport公共合成seam验证正常与各拒绝类别，无真实网络/凭证。只新增guard及测试/证据，05拥有实际调用点与脚本；父级05在正常/失败后验和首次写前完整接入后才可关闭。
- [x] 保留红绿日志与源码、命令、编译器、产物身份；Windows/Linux定向，不跑全量。

## Answer

接口与05约定：`run(allocator, source:anytype, local_ms:i64, expected_uid_hash:[]const u8, allow_btc:bool)!void`；`source.get(path)![]const u8` 借用响应只到下次get，guard必须及时解析。仅GET接口不具有订单写能力。05负责实际source的timestamp刷新、调用与生命周期/失败后验。

首个公共正常路径回归：先`NotImplemented`红，随后Windows Debug1/1绿；独立合成source记录16个精确GET路径（含全部7algo和两份balance），响应复用同一buffer且allocator observer在每次下一GET前要求已释放所有上次响应分配。UID预期SHA由独立Python hashlib固定literal给出，不拿实现自算结果当断言。证据`runs/08-normal-red-v1`、`runs/08-normal-green-v1`保留。

最终2026-10-19封存：[08-evidence.md](../08-evidence.md)、[08-validation.json](../08-validation.json)、[源码包](../08-final-source.zip)。Windows Debug/ReleaseSafe、Linux ReleaseSafe真实WSL ELF各10/10；所有最终capture同源`a959d2646245601347b25338ba7e784a60a192db7c16434e619a6fef3dbc065b`，guard文件SHA`96fefc27d47d2c997e76b4015760a5b21f78107d75f19de3fa73258ab0470d45`。四组历史非零（初始红、leverage shape红、显式空负债兼容红、测试夹具语法错误）原件保留分类；没有panic、timeout、源码漂移或跳过。已合入docs-only最新integration baf6856c，未修改05文件/密码模块/主分支/真实网络，未读.env.local。

本票关闭模块公开合同及合成证据；05仍须使用真实受保护source接入首次写前与正常/失败后验，其调用生命周期不得由本票standalone通过替代。Windows调用allow_btc=false；allow_btc=true只给明确既有cleanup，guard本身无任何写能力，亦无新增生产资格。
