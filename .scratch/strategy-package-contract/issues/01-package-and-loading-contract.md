# 策略包与加载合同 v1

Type: spec
Status: resolved
Assignee: Codex
Blocked by:
Parent: [模块地图](../map.md)

## Question

新增策略如何按统一合同交付、验证、加载、恢复及发布，而不把策略代码、运行配置和交易授权混为一体？

## 完成条件

- [x] 定义包结构、内容身份、签名绑定与兼容规则。
- [x] 定义 Python 入口、事件、输出、状态及资源边界。
- [x] 定义新增、更新、恢复、回退及 Web 操作路径。
- [x] 给出拒绝场景和后续实现验收向量，标明当前能力缺口。

## Answer

2026-10-28：以下为新定义的 v1 合同，不是现有加载器说明或部署授权。resolved 只表示合同定义已交付；接口实现、生产接线和资格均未完成。首版以 Python 中低频策略为具体加载对象，原生策略沿用静态编译。本文的 MUST 条件均使用“必须”；未知或不满足条件时拒绝，不猜默认值。

### 1. 所有权与交付关系

```text
经批准、签名的 ReleaseArtifact
  ├─ RingWin / Host / 固定依赖与运行时
  └─ strategies/<definition-identity>/manifest.json + 声明文件
       ↓ 验证后登记 StrategyDefinition，尚无交易权限
Web ConfigEvent → 运行实例绑定 → 无权恢复/预热 → Ready
       ↓ 当前核心安全条件 + EnableTrading + Host 激活屏障
TradingShard 接受当前授权包络中的候选 OrderIntent
```

- **StrategyPackage**：某一 StrategyDefinition 版本的代码、参数/状态合同、兼容信息及证据。包内容不变，可供多个不同实例使用。
- **运行绑定**：控制面创建的实例身份、VirtualPortfolio、DecisionDomain、账户/品种、配置内容身份和风险预算。它不写回包，也不由策略自行选择。
- **交易授权**：来自现有 ControlCommand、SafetyGate、品种授权及核心激活事实；签名正确、包已安装、健康检查通过都不能代替授权。
- 首版包安装/登记随 ReleaseArtifact 发布，不建立第二个策略包上传后门。可包含多个定义，但一次策略替换只改变明确目标；不兼容 Host/核心升级按 DecisionDomain 等实际影响范围排空。
- 原生 Zig/C 策略在 ReleaseArtifact 构建时静态编译、注册到相应 TradingShard。不得把 Python 的模块入口解释为允许加载 `.so`、`.dll` 或生产节点本地编译。

### 2. Python 包布局与身份

```text
strategies/<definition-identity>/
├─ manifest.json
├─ code/<strategy modules>.py
├─ contracts/config.json
├─ contracts/state.json
└─ evidence/<build-time reports>.json
```

`manifest.json` 固定字段如下；所有字段必填，不提供可交易默认值。

| 字段 | v1 语义与校验 |
|---|---|
| `format_version` | 整数 1；未知版本或未知字段拒绝 |
| `definition_identity` | 非零 128 位身份，32位小写十六进制；一个身份只能绑定一份包 manifest 内容 |
| `name` | 1–64 字符展示名，不作加载或授权身份 |
| `runtime` | 固定 `python`；原生定义走已有构建注册路径 |
| `entrypoint` | `module:create`；module 为包 `code/` 内点分模块名，函数名固定 `create`，禁止路径或命令行表达式 |
| `strategy_api_version` | 整数 1，对应第4节；不是 IPC 版本 |
| `compatibility` | 第3节的精确兼容元组 |
| `config_schema` | `{identity, version, path}`；identity 为非零128位身份，version 为正u32，path 在 files 中 |
| `state_schema` | `{identity, version, path, encoding}`；前述规则，encoding 固定 `portable_json_v1` |
| `subscriptions` | 去重且按数值排序的 `{event_type, schema_version}` 列表；必须在声明 registry 中存在，匹配实际读取能力 |
| `output_kinds` | 排序去重的 `order_intent` / `intent_group` 子集，可为空以声明仅观察；不是交易许可 |
| `limits` | 第3节全部资源上限；真实运行使用包上限与部署允许值中更严格者 |
| `files` | 按 path 排序的 `{path, size_bytes, sha256}` 列表；清点 manifest 以外的全部文件，包含入口、代码、配置/状态合同、证据 |
| `evidence` | 排序去重的 `{kind, path}` 列表，path 必须在 files 中；kind 为 `offline` / `economic` / `operational`，缺项表示未提供 |

编码与内容身份规则：

- manifest 必须为无 BOM 的 UTF-8 规范 JSON：键递归排序、无多余空白、ASCII 转义，禁止重复键、浮点、NaN/Inf；整数必须校验精确类型，布尔不得当作整数。数组顺序按上表固定。对规范字节计算完整 SHA-256，记为 `package_manifest_sha256`；此摘要由包外的发布索引引用，不在 manifest 内自引用。
- 初始 v1 解析硬上限：manifest 256 KiB、files 4096项、单文件64 MiB、全部声明文件256 MiB、subscriptions 256项；超过拒绝。部署可进一步收紧；放宽格式上限须更新合同版本及验收，不能只修改线上配置。
- 文件 path 是包根下区分大小写的相对 POSIX 路径；禁止绝对路径、空段、`.`/`..`、反斜线、冒号、控制字符、链接、设备文件及仅大小写不同的重名。禁止包外解析、未声明文件和解压后越界；校验实际字节数及 SHA-256。构建前生成的缓存文件不进入包，运行中禁止写包目录。
- 包文件、发布索引和固定依赖必须全部处于外层 ReleaseArtifact 的签名与 payload 内容哈希覆盖下。索引为 `strategy-index.json`，只含 `format_version:1` 和按身份排序的 `strategies:[{definition_identity, manifest_path, package_manifest_sha256}]`；manifest_path 固定为上述布局。索引身份与 manifest 身份不符、同身份不同内容、丢文件均拒绝。
- 不新增弱于现有发布签名的策略签名通道；外层验签信任根、批准和 allowlist 沿用既有发布机制。注册记录保存 ReleaseArtifact 身份、manifest 全摘要和校验结果；u128 身份不得代替 SHA-256 完整性校验。
- 对最终包的资格报告保存在包外，按既有资格证据机制认证并绑定 `package_manifest_sha256` 及第3节要求的运行范围。包内 evidence 只保存构建时已固定、明确注明被测源码/构建对象的证据，不要求其引用包含自身的最终包摘要；后续资格结果不回写已冻结包，也不新增证据系统。
- 第三方依赖由外层 ReleaseArtifact 锁定并离线提供，不从包运行安装脚本、`pip install`、Git URL或加载未签名扩展。新增原生 Python 扩展必须作为外层运行时依赖重新构建和取得相应平台资格。

### 3. 兼容、配置与能力

`compatibility` 必须包含且仅包含：`host_build`、`python_abi`、`host_protocol`、`schema_registry`、`runtime_lock_sha256`。前三个整数身份/版本复用 HostSupervisor 的对应校验，schema_registry 为32位非零十六进制身份，runtime_lock_sha256 为64位小写摘要。host_build 在 JSON 中也编码为32位非零十六进制；python_abi 为正u32，host_protocol 为正u16。必须精确匹配部署批准的运行时，不接受 `>=`、`latest` 或版本范围。

`limits` 必须包含正u64整数：`max_private_state_bytes`、`max_input_record_bytes`、`max_output_frame_bytes`、`max_output_frames_per_event`、`max_callback_ns`、`max_warmup_events`、`max_warmup_ns`、`max_memory_bytes`。前三者必须同时满足现有 codec/IPC 容量；输出帧数由宿主检查，回调/预热/内存预算由 HostSupervisor/OS 在 Host 外监督，Python 自报耗时不能授予资格。不可计量或目标平台未实现的硬限制使该部署资格不完整，不能默认为无限。

多实例共用 Host 时，内存计量口径、包上限到进程预算的映射及实例放置由加载器实现票明确，不要求同一 Python 进程内逐实例硬隔离。Host 被终止时，其全部实例按既有会话失效路径撤权并恢复；目标实例替换若需重启共享 Host，必须展示这一实际影响范围。模块命名与加载组织留在实现票中解决，不扩展为恶意插件隔离机制。

控制面运行绑定必须包含：

- ReleaseArtifact、StrategyDefinition、package_manifest_sha256；StrategyInstanceIdentity、VirtualPortfolio、DecisionDomain，以及核心分配的目标归属。
- ConfigVersion 和已认证配置字节的完整内容哈希；宿主先检查规范JSON字节、大小与身份，再由第4节固定入口按包内config_schema执行结构/语义校验。相同 ConfigVersion 不得绑定不同内容，未知/缺失字段拒绝。风险阈值、费用、模型等禁止填入可交易示例默认值。
- 规范 Venue/ExchangeAccount/Instrument 范围、输入订阅、允许输出类型、模式/产品资格引用、风险预算与当前允许值。资格报告须绑定完整包/配置/平台/环境/模式范围；存在 evidence 文件不表示 qualified。
- 初始状态/恢复策略与证据：无历史新实例显式初始化；已有实例必须绑定 checkpoint 内容身份、cursor、依赖和恢复屏障，不能以“启动失败”改用空状态。

config_schema/state_schema文件是对应策略拥有的版本化字段合同，必须列出字段、类型、单位、范围、容量、编码及未知/缺失字段处理；身份和版本一经发布不可改义。v1不新建通用JSON Schema解释器，具体结构/语义由该签名包的固定验证器实现，并以schema对应的正/反向验收向量交付。宿主只承担通用身份、编码、容量和包络检查，不能从文件名推断某个策略schema已受支持。

包中不得包含真实账户密钥、签名私钥、口令、实例交易授权或可变 checkpoint。可复用算法参数/模型可以作为已哈希文件交付；账户绑定、预算及显式激活仍在配置和核心事实中。

### 4. Host 内部策略 API v1（待实现）

这是 Python Host 内的固定调用合同，不新增跨进程 RPC，也不修改现有 IPC wire 格式。以下为语义签名；未来 SDK 必须提供对应不可变 DTO 与验证器，现有 `strategy_host.py` 尚无通用插件入口。

| 入口 | 输入/输出与责任 |
|---|---|
| `validate_config(config_bytes) -> None` | 与create位于同一入口模块；按包内config_schema完整检查结构/单位/边界及不变量，不能插入默认值或修改配置；在候选Host中、create之前调用 |
| `create(context, config_bytes) -> instance` | 无权初始化；context 为宿主验证后只读身份/依赖，config_bytes 已校验且内容不可变；不得生成外部动作 |
| `instance.on_event(event) -> tuple` | event 为 `{sequence, event_type, schema_version, payload_bytes}`，来自现有规范输入解码路径；返回有界的 OrderIntent / 完整 IntentGroup 建议集合，或空元组 |
| `instance.next_intent_sequence -> int` | 只读正u64属性，与snapshot内进度一致；宿主用它校验输出连续序号和checkpoint包络，不依赖宿主live计数补发 |
| `instance.snapshot() -> bytes` | 显式 schema 的 PortableStrategyState 私有 payload；宿主加现有 checkpoint 身份/cursor/摘要包络，禁止任意对象序列化 |
| `instance.restore(payload_bytes) -> None` | 验证后替换私有进度；不恢复核心订单、资金或权限，异常即拒绝，不静默部分恢复 |
| `instance.validate() -> None` | 验证当前私有状态不变量及预热完成条件；失败抛出稳定原因，不能通过修状态把失败改成成功。状态合法但预热未完成仍不得通过激活前检查 |

context 字段固定为 `strategy_identity`、`definition_identity`、`config_version`、`config_sha256`、`package_manifest_sha256`、`state_schema_identity`、`state_schema_version`；编码遵守上述身份/摘要格式。它不是网络、文件系统、核心查询或发单能力句柄，不携带凭证与激活权限。

事件与输出规则：

- StrategyInputBatch 分批边界对算法不可见；同一有序事件流以不同批大小传入，决定和状态摘要必须一致。宿主验证完整 ShardSequence 覆盖与订阅过滤，策略回调不因过滤后可见 sequence 的跳跃误判日志缺口；StrategyCursor 在批次覆盖的实际进度上推进。
- payload_bytes 的格式由精确 schema registry 决定；缺 schema、输入缺口或无新鲜度证据必须停止相关新增风险。事件时间取权威输入；本地墙钟、未登记随机数、网络请求、目录扫描和全局共享可变状态不得影响重放决定。
- 输出仅使用已有规范 OrderIntent/IntentGroup 结构和 codec。StrategyInstanceIdentity + IntentSequence 的分配状态包含在私有状态，live 与无权 replay 按相同路径消耗序号；宿主在恢复/影子时丢弃外发，不能仅在 live 分配序号。每次回调的输出成员序号必须从回调前next_intent_sequence连续分配，组保持完整稳定顺序；回调后的属性必须等于原值加全部输出成员数，空输出不得推进。序号溢出拒绝，checkpoint外层与payload进度不一致拒绝。不得返回部分组、OrderCommand、核心授权证明、交易所客户端订单号或私有Venue消息。
- 运行适配层负责将当前 HostSession/StrategyActivation/来源batch/cursor等真实证据加到输出包络。包不能伪造或自行启用这些字段。核心和 Gateway 仍执行共同准入及发送前权限复核。
- snapshot 不得包含未声明字段、pickle/marshal、解释器对象或权威经济副本。浮点研究状态沿已声明 codec 的精确 bit 编码，不把裸 JSON 浮点混入 PortableStrategyState。随机算法必须冻结算法/seed，并保存推进状态。
- Host 记录 callback 异常、超时、容量及合法最后 cursor，通过既有 fault/recovery 路径撤权。不得跳过坏事件继续发单，或把未完成回调标为已应用。异常后的可疑私有状态不发布为有效 checkpoint。
- Python Host 是受限的可信发布代码执行容器，不是任意第三方 Python 的安全沙箱。生产启动必须清洁环境/导入路径，只允许包内代码、签名依赖和标准库；实际模块解析路径须与清点文件一致，不能被当前目录或全局 site-packages 覆盖。导入在隔离候选 Host 进行，不在核心或 Web 后端导入。

v1 不提供 `Migrate` 调用 ABI，因此包加载器必须拒绝选择Migrate，不能执行任意迁移脚本或偷偷降级为Rebuild。领域仍保留这一转换方式；后续需要时须另行版本化迁移ABI，绑定明确源/目标包、状态schema、配置及输入输出摘要，在受限候选流程中验收确定性与不变量后才允许启用。

### 5. 验证、加载及运行激活

以下是发布工作步骤，不新增另一套 OperationalMode。实际实例状态仍为 Stopped / Recovering / Ready / Trading / Draining；候选加载及影子不是 Trading。

1. **构建**：在受控构建机冻结源码、依赖、解释器、Host/核心版本、包文件与测试证据；生成索引和外层签名 ReleaseArtifact。生产节点不编译、不联网装依赖。
2. **发布前验证**：后端核对 OwnerSession、命令身份、目标、预期当前版本和完整内容哈希；节点核对签名、批准/allowlist、索引、全部文件、兼容元组、schema、订阅及资源限制。检查不执行策略代码。
3. **隔离加载**：在不可写版本目录安装全部已校验文件；启动无网络/凭证/发送能力的候选 Host。导入入口、create、初始化/restore、checkpoint 往返和重放检查都在交易权限关闭时完成；预热后的validate见下一步。包目录安装失败不得切换 current 或部分登记定义。
4. **恢复与就绪**：按原 checkpoint cursor 无权重放到指定屏障，核对 StrategyStateDigest、next IntentSequence 与核心事实引用；新实例完成初始化及预热。激活前调用validate检查包内合同声明的预热完成条件；数据不足或达到预算仍未完成时不得激活，无需新增readiness接口。重建不能抹除原周期、Unknown、尾差或风险锁存。缺日志或持仓管理语义不兼容时保持 Recovering/Ready且禁止新增风险，不以Rebuild绕过。
5. **受控切换**：代码替换/配置切换执行对应范围的撤权、CutoverDrain和同屏障一致性检查，再提交 VersionActivationEvent。活跃订单未对账、Unknown、候选落后或持久化失败均不得完成切换。Host 的 HostActivated 屏障独立验证，不以一个版本指针代替另一授权事实。
6. **显式启用**：本合同 v1 对新实例、参数发布及人工代码切换一律不自动扩大/恢复交易授权；切换完成可停在 Ready，由 SystemOwner 通过既有 EnableTrading 显式启用。若部署流程合并显示，后端仍须分别记录和验证发布与启用命令。所有 SafetyGate 与账户/品种限制同时满足才可 Trading。

Web 沿用 DeployRelease / ForwardRollback、配置与实例管理、只读状态和 EnableTrading 操作。一次 DeployRelease 的确认覆盖其候选验证/排空/切换，无需每一步重复确认；它不等于 EnableTrading。Web展示包/配置身份、目标范围、转换方式、资格缺口、当前实际运行版本、状态及失败原因；结果 unknown 不展示成功，重试同一命令身份不得重复应用。新增实例配置表单/API及包列表为待接线能力，不声称当前已有。

### 6. 新增、更新、重启和回退

| 场景 | 身份与处理 |
|---|---|
| 添加不同策略 | 注册新 StrategyDefinition，创建新 StrategyInstance；默认分配独立 VirtualPortfolio。若使用已有 VirtualPortfolio，必须作为原策略的显式接替，禁止两个实例同时取得该组合授权 |
| 修改任何算法代码 | 新包、新 StrategyDefinition身份和新 StrategySuccessor身份，保留原VirtualPortfolio及核心历史；v1仅支持Rebuild，且必须先确认旧实例管理责任闭合，不能原地覆盖已签名文件 |
| 只修改参数 | 定义不变、ConfigVersion及内容身份更新，实例身份不变；仍走配置校验、状态转换、排空/激活与显式启用，不自动放宽现有周期目标/期限 |
| Host崩溃或普通重启 | 原实例/定义/配置及IntentSequence历史保留，HostSession generation和激活身份按核心事实更新；先恢复/对账，不能当作新策略清空预算或锁存 |
| ForwardRollback | 旧代码作为新一次候选发布，创建新Successor并验证当前历史/配置兼容；同样满足v1的Rebuild及旧责任闭合条件，旧定义内容身份不被改写。绝不恢复旧资金、订单、持仓或权威快照 |

v1的Keep仅用于同一实例内的兼容参数转换；普通重启恢复也必须保留原进度。Keep须证明私有状态schema、配置/模型依赖与语义兼容；只检查schema version相同不够。依赖内容改变时，只有经验证的兼容规则才能复用进度，否则拒绝Keep。v1不接受Migrate，也不提供跨实例私有状态承接；这是避免把旧意图分配器、原周期引用或锁存误复制到新身份的首版限制，不改变领域中三种转换方式的定义。

Keep复用现有API：验证新配置和已声明的兼容规则，以新context/config创建无权候选，再restore同一实例的已验证旧payload，追赶至切换屏障后validate；恢复不得覆盖新配置。候选保留原意图分配进度，并在无权追赶中按正常事件路径推进。同实例Rebuild须在对应策略合同中写清如何通过现有API保留意图分配和存量管理进度、仅重建允许重建的指标；宿主不得猜测payload字段、修改只读序号或将旧序号重置为1。现有API无法表达该过程的策略，v1拒绝其同实例Rebuild，不为此预建通用迁移接口。

因此代码替换/回退激活前，旧实例必须无活动周期、未完成订单、Unknown、未处理迟到事实、未闭合经济责任或需其管理的仓位/残余；不满足时可登记候选包，但拒绝接替。不得由发布器自动平仓或丢弃尾差，应先通过既有另行授权的风险处置/对账流程闭合。新Successor以Rebuild初始化新私有状态和从1开始的意图序号；原VirtualPortfolio资金、核心经济历史及其风险约束不重置。同实例的参数更新即使Rebuild指标，也必须保留原next IntentSequence、存量管理进度及风险锁存；不可分离则拒绝该转换。未来允许持仓接替时，必须另行定义原身份管理与新身份分配的承接合同并验收，不能直接解除此限制。

候选验证失败时旧版本保持当前权限，记录拒绝；排空后切换前失败则旧版本不自动复权。激活后失败先停止新增风险，再走恢复或 ForwardRollback，不自动回滚经济状态。无法确认当前实际运行版本时记录 unknown 并保持风险关闭，不能以文件链接指向某版本推断其已运行。

### 7. 后续实现的验收向量

这些是待执行的验收要求，本次文档检查不把它们标记为通过。

切换恢复优先复用既有发布、持久化与幂等合同；实现票先核实已有覆盖，再为新增包安装/激活接缝补必要的中断与重试验收，不另建恢复协议或重复整套故障矩阵。

| 向量 | 预期结果 |
|---|---|
| 合格包只安装/登记，未EnableTrading | 可观察/无权恢复，无订单/预留/可发送输出 |
| manifest/任意模块/依赖被改一字节；同定义身份不同内容 | 在导入前拒绝，不切换旧版本 |
| 路径越界、链接、重复JSON键、未知字段或超容量 | 验证失败关闭；无包外读写或部分安装 |
| entrypoint同名模块出现在工作目录/全局site-packages | 不允许解析到非清点文件，拒绝覆盖或清洁路径后仅加载批准模块 |
| Host/ABI/protocol/registry/依赖锁不匹配 | 拒绝启动候选，不降级旧wire，不自动联网安装 |
| 无效参数/旧ConfigVersion冒用新内容/资格范围不匹配 | 不创建获权实例，不填示例阈值或继承其他模式资格 |
| 一个事件流分成不同批次；同一checkpoint+相同尾日志 | 决策、私有摘要、序号一致，无权重放零外部效果 |
| 缺checkpoint、尾日志缺口、未知schema或不兼容Keep | 不清空状态重新开始；保持恢复或拒绝切换 |
| 私有状态合法但预热未完成，或耗尽预热预算 | 激活前validate不通过，不因状态结构合法而授予交易权限 |
| 选择Migrate但只支持本合同v1；输出序号跳号/重复或checkpoint进度不符 | 明确拒绝，不能隐式Rebuild或重编号后发送 |
| 同组合启动第二个获权实例；跨DecisionDomain原子组 | 核心拒绝，包/配置不能绕过归属限制 |
| callback异常/超时/输出超限/内存超限 | 有界告警及既有fault撤权；可疑状态不发布checkpoint，不影响其他Host的核心推进 |
| 旧Host/旧激活输出在切换后迟到 | 核心拒绝旧包络，不复用新会话发送 |
| 未确认撤单/Unknown/存量周期无法承接时更新 | 不完成激活、不生成新身份重发；保留原周期、占用及风险锁存 |
| 同发布命令重试/当前版本前置条件冲突 | 幂等返回原结果，或明确冲突；不重复部署或启用 |
| 激活后崩溃/回退到旧代码 | 停新增风险；经济历史不回滚，新Successor仍须兼容和显式授权 |
| 合成回归/离线影子通过，无真实资格 | 可保存开发证据；经济/运行资格pending，不显示可生产交易 |

### 8. 当前源码对应与实现缺口

| 现有来源 | 已有边界 | 本合同仍需实现/接线 |
|---|---|---|
| [HostSupervisor](../../../src/strategy/strategy_host_lifecycle.zig) | 精确Compatibility、启动/故障/恢复及激活消息 | 从批准的索引/包/运行绑定产生真实manifest与checkpoint兼容证据；通用加载入口 |
| [Python Host](../../../python/strategy_host.py) | framing、恢复/checkpoint传输及测试模式 | 固定策略API、入口注册与事件/意图适配；portable模式目前拒绝非空尾日志，不能当作通用恢复完成 |
| [策略checkpoint](../../../python/arbitrage_checkpoint.py) / [状态codec](../../../python/strategy_state.py) | 跨所策略实际组件及显式Portable状态编码 | 新策略自己的schema/验证器与宿主注册；不能直接把现有跨所schema作为所有策略状态 |
| [Cutover](../../../src/runtime/recovery_cutover.zig) | 候选、排空、持久版本激活与恢复边界 | 将包/配置身份与真实候选、策略私有迁移/恢复及Host激活接通；布尔candidate检查不替代验收 |
| 现有Web `D:/github/Ringwin-control-plane/python/control_plane_web.py` | DeployRelease、ForwardRollback、OwnerSession及签名发布后端入口 | 包/实例配置展示与提交、真实节点状态/资格投影及完整端到端操作 |
| 现有 `D:/github/Ringwin-control-plane/python/release_lifecycle.py` | 签名ReleaseArtifact、payload哈希、幂等记录、版本目录及systemd适配 | **当前FilesystemApplier只复制单一payload为ringwin**；需要将签名覆盖扩展到索引、包文件与运行时，并验证/原子安装。不得直接把压缩包传给现有二进制applier冒充支持 |

源文件核对日期为2026-10-28。既有Host的strategy_manifest/checkpoint_manifest均为固定摘要字段，本合同不重新定义其wire含义；聚合多策略/多checkpoint摘要的规范适配仍需在上述接线中定义和测试，不能随意截断完整包摘要或复用占位值。

2026-10-29评审收窄：本次补充证据绑定、参数转换和预热检查语义；加载组织、资源计量及恢复接线留给对应实现票，不作为拆票前必须另建机制的阻塞项。原生合同仍是已登记待办，无持仓接替仍是v1范围限制，不要求本轮扩展。

### 9. 依据、校验与范围

- 使用[根级术语](../../../GLOSSARY.md)；新增StrategyPackage仅补交付单元，不改变StrategyDefinition/Instance/Successor或经济所有权。
- 遵守[ADR0003生产role](../../../docs/adr/0003-linux-production-process-chain.md)、[ADR0007匿名pipe](../../../docs/adr/0007-use-validated-pipes-for-strategy-host-data.md)、[ADR0012品种权限](../../../docs/adr/0012-bind-observation-and-trading-state-to-instruments.md)、[ADR0017单DecisionDomain](../../../docs/adr/0017-own-cross-account-groups-in-one-decision-domain.md)、[ADR0020多组合归属](../../../docs/adr/0020-own-multiple-portfolios-in-one-decision-domain.md)和[ADR0021安全锁存](../../../docs/adr/0021-preserve-account-safety-causes-through-recovery.md)。没有重开这些决定，也不新建共享内存接口或控制面CLI。
- 本次只检查领域/源码对应、文档链接及diff格式，不运行加载器、真实发布、迁移、交易或生产资格测试。第7节全部是未来实现验收条件。
- 已执行临时Python文档检查：三份变更文件UTF-8、全部相对链接、尾部/行尾空白及tracker状态边界断言通过；`git diff --check`通过。没有为纯文档变更运行行为测试。
- 不新增包商店、通用工作流、热更新原生库、生产安装脚本或第二套资金/订单权威；本次不拆分实施票、不修改其他模块资格状态。
