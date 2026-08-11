# 定义密钥、安全边界与操作授权

Type: grilling
Status: resolved
Blocked by:
Parent: [设计生产级多策略低延迟加密量化交易系统](../map.md)

## Question

交易所凭证、策略包、配置、风险额度和 Kill Switch 应由谁持有、如何授权与审计，哪些操作需要双人审批或硬件隔离？

## Answer

规范安全与操作词汇记录在 [`CONTEXT.md`](../../../CONTEXT.md)。

### Human and machine authority

- 首版只有一个 SystemOwner，拥有全部人工控制权限；不设计虚假双人审批或复杂人工授权等级。
- 交易核心、执行网关、控制面、研究和部署任务分别使用独立、可撤销的 MachineIdentity，权限不能互换。
- 高风险人工操作只展示 RiskWarning，SystemOwner 普通确认后即可执行，不要求操作级二次认证。
- MachineIdentity 不能代替 SystemOwner 发起人工控制操作，也不能扩大自身权限。

### Owner authentication

- 控制面只通过管理 VPN 或专用管理网访问，不直接监听公网。
- SystemOwner 使用主认证加 TOTP 建立最长 12 小时的 OwnerSession；会话内不再进行操作级二次认证。
- 主认证使用加密 SSH key 或密码，不使用短信验证码；禁止共享账号、默认密码或仅靠来源 IP 识别操作员。
- TOTP 恢复码离线保存，使用后立即轮换；恢复材料不能与生产凭证共用。
- 本地紧急控制台只能触发 KillSwitch，不能绕过 OwnerSession 恢复交易、修改配置或管理凭证。

### Credential storage

- TradingCredential 以加密文件形式保存在 CredentialStore，数据库、代码库和普通配置文件不保存明文。
- 首版由 SystemOwner 在生产节点启动时使用独立解密口令手工解密；TOTP 不能作为静态文件加密密钥。
- 解密后的 SecretMaterial 只进入对应执行网关的锁定内存，不通过环境变量、命令行、普通临时文件或日志传递。
- 生产进程禁止 swap、core dump 及非授权 ptrace。
- TPM 不是首版强制依赖；未来需要无人值守启动时可使用 TPM 自动解封。
- 节点启动解密口令、OwnerSession 主认证和 TOTP 使用相互独立的秘密及恢复材料。

### Credential separation

- 每个 Venue、ExchangeAccount、环境、节点和用途使用独立 TradingCredential；生产、测试、只读采集和交易权限不得共用。
- ObservationCredential 只读账户、订单、成交和仓位，用于对账、监控及热备预热，不能升级后复用为交易用途。
- ExecutionCredential 只由执行网关持有，并受 MachineIdentity、fencing token、RiskLease 和执行安全栅栏约束。
- Venue 支持足够 API key 时，主节点与热备节点分别使用自己的 ExecutionCredential，以便独立审计、轮换和吊销。
- Venue 限制 key 数量或能力时才允许主备共享加密 ExecutionCredential，并在能力契约中标记安全降级。
- 凭证只允许对应节点固定出口 IP；私有请求记录 credential_id 而不记录 secret。

### Credential permissions

- ExecutionCredential 只允许读取账户、余额、仓位、订单、成交、Instrument 和费率，以及交易首版目标现货与 USDT 线性永续。
- 永久禁止提现、链上地址、内部/子账户资金划转、账户模式、API key、用户、跟单、理财、借贷和经纪商管理权限。
- ObservationCredential 仅授予读取权限，不具有订单或账户修改能力。
- 账户模式由 SystemOwner 在 Venue 官方界面预设，执行网关启动时只验证，不通过 API 自动改变。
- ExternalTransfer 由 SystemOwner 在 Venue 官方界面手工完成，系统只读取并记账。
- Venue 将交易与资金移动或账户管理捆绑且无法排除时，该凭证不得通过生产准入。
- 执行网关启动及运行期间复核权限；发现权限扩大或状态不明时触发 KillSwitch 并 fail closed。

### Credential lifecycle

- CredentialState 使用 `Staged → Active → Retiring → Revoked`；同一节点与用途同一时刻只有一个 Active 版本。
- ExecutionCredential 默认每 90 天轮换，ObservationCredential 默认每 180 天轮换；Venue 更短期限优先。
- 新凭证在 Staged 状态验证账户身份、权限、IP 白名单、时间同步、私有查询和签名，通过后才可激活。
- 激活通过版本化 ControlCommand 在明确屏障生效；旧凭证进入 Retiring 后不能签署新的增加风险请求。
- 完成订单、成交、Unknown 和账户对账后，旧凭证最长保留 24 小时即吊销。
- 到期前 30、14、7、1 天告警；过期或状态不明时只允许使用有效凭证降低风险。
- 怀疑泄露时立即触发账户 KillSwitch、吊销凭证并对账，不等待正常重叠窗口。
- Revoked 凭证不能通过配置回滚恢复。

### ReleaseArtifact trust

- TradingShard、执行网关、控制面和 Python Strategy Host 由隔离构建任务生成 ReleaseArtifact，生产节点禁止本地编译。
- Artifact 记录源代码版本、工具链、依赖锁、构建参数、测试结果、内容哈希和兼容状态；构建环境不得持有生产凭证。
- ReleaseArtifact 使用控制机上的加密软件签名密钥签名，不要求硬件安全密钥。
- 生产节点只加载签名有效、哈希匹配、已经 SystemOwner 批准且位于允许列表的 Artifact。
- Python 环境使用锁定依赖和包哈希，生产运行时禁止联网安装。
- 原生策略静态编译进 TradingShard；首版不增加动态插件加载器或远程代码执行能力。
- 蓝绿发布和回滚只能选择已批准 Artifact，且不能绕过当前安全及状态兼容检查。

### ControlCommand

- 配置、风险上限、策略启停、发布切换、凭证状态、主备切换和交易恢复通过不可变 ControlCommand 下发。
- ControlCommand 包含唯一 command_id、明确目标、命令类型、内容哈希、期望当前版本、签发时间和过期时间，并由控制面 MachineIdentity 使用软件密钥签名。
- 接收者验证签名、目标、期限、当前版本和 command_id；重复命令返回原结果而不重复执行。
- 旧版本、过期、目标错误或版本前置条件不匹配的命令 fail closed。
- KillSwitch 可以由多个安全来源幂等触发，不因 ControlCommand 过期或控制面失联自动解除。
- 控制面失联后，交易面只在现有 ConfigEvent、RiskLease 和凭证有效期内继续。

### Risk ceilings

- StrategyLimit 规定每个 VirtualPortfolio 的资金、敞口、单笔订单及速率限制，可通过版本化 ConfigEvent 热更新。
- AccountSafetyCeiling 由执行网关对整个 ExchangeAccount 强制执行，包括账户总敞口、单笔名义金额、订单速率和 Venue/Instrument 范围。
- StrategyLimit 必须小于等于 AccountSafetyCeiling；超出时配置直接拒绝，不能只提示后放行。
- 策略、Python Host 和 TradingShard 不能修改 AccountSafetyCeiling。
- SystemOwner 修改 AccountSafetyCeiling 时查看旧值、新值、变化倍数及最大资金影响的 RiskWarning；降低立即生效，提高在明确版本屏障生效。
- 提现禁用、凭证用途隔离及 fencing token 校验是不能通过配置关闭的绝对规则。
- 执行网关执行最终风险检查，即使上游配置或策略错误也不能突破上限。

### KillSwitch and Flatten

- KillSwitch 支持全局、Venue、ExchangeAccount、DecisionDomain 和 StrategyInstance 范围。
- 触发后，TradingShard 与执行网关立即拒绝增加风险的 OrderCommand，并撤销相关存量挂单；撤单确认前保留 RiskReservation。
- Reduce-only、必要减仓和对账继续允许。
- KillSwitch 默认不自动市价平仓，避免异常行情或流动性不足时制造确定性冲击损失。
- Flatten 是 SystemOwner 查看仓位、盘口及预估影响后单独发起的归零操作，只需 RiskWarning 普通确认。
- 自动风控、凭证失效、行情 Gap 和 SystemOwner 均可立即触发 KillSwitch；触发本身不显示阻塞提示。
- Kill 状态由执行网关本地强制，即使控制面失联仍有效。
- 恢复前必须完成订单、成交、余额和仓位对账并确认行情健康，再由 SystemOwner 普通确认。

### Process and network isolation

- TradingShard 不拥有公网 socket，也不读取生产凭证；只通过本机有界通道与行情/执行网关通信。
- 执行网关是唯一访问 Venue 私有 API 并持有 ExecutionCredential 的进程，出站网络只允许目标 Venue 端点。
- 行情网关只访问公共行情端点，不具有交易权限。
- Python Strategy Host 禁止任意公网访问，只读取已批准策略包并通过受控 IPC 与交易核心通信。
- 控制面、研究数据面和交易面使用不同 Linux 用户和 MachineIdentity；研究节点不能连接执行网关私有接口。
- 生产进程均以非 root 用户运行；root 只用于节点配置、服务安装和内核/网卡管理。
- 使用 systemd 原生文件系统只读、私有临时目录、能力集裁剪、禁止提权、进程/设备访问及资源限制；不引入容器编排或服务网格。
- 本机进程间使用 Unix domain socket 或既定共享内存通道。控制面只暴露有限命令，不提供通用远程 shell。
- 运维 SSH 与交易网络入口隔离，生产服务不监听公共管理端口。

### Minimal operator records

- OperatorRecord 只在人工操作实际改变生产状态时写入，包括凭证、ReleaseArtifact、策略、风险上限、Venue/账户/Instrument、KillSwitch、Flatten、恢复及主备切换。
- 每条只记录时间、OwnerSession、操作类型、目标、变更前后版本或哈希、结果及 correlation_id，不记录 SecretMaterial。
- ReleaseRecord 是发布批准、部署、回滚和软件签名密钥变化的发布专用 OperatorRecord，不重复写第二份事件。
- 普通读取、页面浏览、RiskWarning 展示、构建过程和一般拒绝加载不进入长期审计。
- 自动风控、订单和成交继续记录在分片决策日志，不在 OperatorRecord 重复。
- OperatorRecord 写入现有控制面日志，保留期由 RetentionPolicy 和空间策略决定，本票不规定固定年限。
- 不建设独立 SIEM、区块链审计或复杂安全事件平台。

### Sensitive logging

- API secret、私钥、恢复凭证、Authorization header、Cookie、登录令牌和完整请求签名材料不得出现在日志、指标、SourceArchive、RunArtifact 或错误信息中。
- 允许记录 credential_id、MachineIdentity、Venue、内部 ExchangeAccount 标识、非敏感请求路径、Venue request id、correlation_id 和筛选后的错误码。
- 私有订单、成交、余额和仓位回报是审计与对账事实，可以封存；发布到研究数据面时继续遵守脱敏规则。
- 出站请求必须在进入通用日志前按结构化字段筛选，禁止先序列化完整对象再做字符串替换。
- 生产执行网关禁止完整 HTTP/WebSocket 头和请求体 debug trace；未知响应先经过受限解析，不能直接拼入日志。
- 检测到疑似 SecretMaterial 时丢弃该日志记录并告警。

### Secure failover

- fencing token 防止正常软件双主；NodeFence 约束仍持有 ExecutionCredential 的失控旧节点。
- 提升热备前，必须从旧节点之外通过网络、路由、防火墙或凭证控制建立 NodeFence，确认旧主无法访问 Venue 私有交易端点。
- 主备使用独立 ExecutionCredential 时，无法证明旧节点隔离就先在 Venue 吊销旧凭证，再提升热备。
- Venue 被迫共用 ExecutionCredential 且没有可靠 NodeFence 时禁止切换，保持 KillSwitch 并人工处置。
- 计划切换先撤销旧主交易权限、确认无在途命令并完成对账，再向新主授予 fencing token。
- 旧节点重新加入前清除旧 credential lease、启动批准 Artifact、完成状态重放和对账，只能先作为热备。
- NodeFence 建立与解除形成 OperatorRecord，只显示 RiskWarning，不要求复杂审批。

### SecurityAdmission

- 执行网关只有在 ReleaseArtifact、MachineIdentity、ExecutionCredential 权限、账户模式、Instrument 白名单、AccountSafetyCeiling、fencing token、RiskLease、KillSwitch、私有连接、初始对账和节点隔离检查全部通过后才能进入可交易状态。
- 出站网络限制、core dump 禁用、非 root 身份、文件权限和日志脱敏自检属于节点准入。
- 凭证权限、账户模式、KillSwitch、租约和 fencing 状态在运行期间周期复核。
- 关键检查失败立即禁止新增风险，仍允许撤单、Reduce-only 和对账。
- 完整检查在启动和外围线程执行，不进入每笔订单热路径；热路径只读取已发布的紧凑安全状态与版本。
- 检查失败记录一条聚合原因，不为每个子检查建设复杂审计事件。

### Security incidents

- 怀疑 TradingCredential 泄露或异常订单时，立即触发对应 ExchangeAccount KillSwitch 并在 Venue 吊销凭证。
- 怀疑生产节点失控时，从节点外建立 NodeFence；该节点状态和凭证不再可信，不能直接重新加入。
- 怀疑控制面或 ControlCommand 签名密钥泄露时，触发全局 KillSwitch、停止配置及发布并轮换控制密钥。
- 怀疑 ReleaseArtifact 或发布签名密钥泄露时，停止部署、回退至已知可信版本并轮换发布密钥。
- 隔离后使用 ObservationCredential 对账订单、成交、余额和仓位，不根据可疑本地状态猜测。
- 恢复必须使用干净节点、批准 Artifact、新凭证及完整对账结果；不自动恢复，由 SystemOwner 查看 RiskWarning 后普通确认。
- 只记录一条事故 OperatorRecord 及既有交易/对账事实；详细步骤留给[定义操作员生命周期工作流](26-operator-lifecycle-workflows.md)。

## Comments

- 2026-07-27：经逐项安全与操作授权访谈确认并解决；采用单一 SystemOwner、TOTP 登录、加密文件手工解密、软件签名和精简 OperatorRecord。
