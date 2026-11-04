# Hyperliquid 运行接线

本配置及入口完成离线组装，不授予 Testnet 或生产资格。协议依据见
[字段合同](research/2026-11-02-hyperliquid-protocol-contract.md)，实际实施证据见
[07](../.scratch/hyperliquid-adapter/issues/07-runtime-cross-venue-wiring.md)。

`src/runtime/hyperliquid_runtime.zig` 接收现有 Owner、Gateway、DurableStore、时钟与
egress Budget，组装独立 VenueAdapter / MarketFeedAdapter。它不拥有 OMS、风控、经济状态
或第二个 Writer。Gateway 账户路由从 Owner 的对应账户视图读取已激活规则及 capability；
缺失、版本、环境、session 或产品不匹配均拒绝。capability 刷新不修改 InstrumentTradingAuthorization。

节点先由现有控制面选择不可变配置 artifact，把批准的 SHA-256 与原始配置字节传给
`Configuration.parse`，并持有解析结果直至 runtime 退出。不得把首次观察的 metadata 摘要
当作批准值。配置字段为：

| 字段 | 约束 |
| --- | --- |
| `schema` | 1 |
| `epoch_startup` | 首次明确 `virgin`；重启 `recover`（默认）。错用 virgin 的后续日志追加会拒绝，不能覆盖旧高水位 |
| `profile` | 明确 Venue、资金账户地址、ExchangeAccount、session、版本、产品、真实 token→Asset 绑定；`can_read=true`、`can_trade=false` |
| `feeds` | 1–8 个品种，独立 subscription/session，固定批准的 `expected_metadata_digest`；公共与私有品种、数量/价格单位及索引精确一致 |
| 私有 `wire_asset` | 永续等于公共 `universe_index`；现货等于其加 10000，溢出拒绝 |

配置中的规则、资产与 capability 必须已由 Owner 提交；runtime 不激活配置或发放交易授权。
同一 egress 的所有私有查询、写入和公共请求必须共享注入的 `hl.Budget`；公共 transport
发出 REST 查询前同样调用该实例的 `take`，不能为每个账户各建一份 IP 配额。订阅 epoch
的消费使用同一预算，保留撤单容量。真实共享 egress 拓扑和实际 transport 由在线节点验收证明。

资源只有三类，不能使用 OKX 的 Demo 开关：

- `offline`：仅注入脱敏 fixture 回调；无凭证加载路径。
- `read_only`：Testnet transport，无钱包签名能力；不能发送订单。
- `testnet_write`：Testnet 钱包、资金账户、session、GatewayLeaseGuard 必须匹配；另需
  `hyperliquid_testnet_write_authorized` 和未到期的单调时钟期限。签名前及实际提交前再次检查。

生产环境不在此配置环境集合内。凭证、主备隔离、共享 nonce 存储和真实 sockets 仍属于既有
节点资源所有者；此模块不读取环境变量或密码文件。凭证/session 切换不能覆盖旧订单或
Unknown：Owner / Gateway 保留旧身份与占用，私有恢复沿 06 的 checkpoint / RawIngress
流程执行，不能用新 runtime 实例清除它们。

账户模式、逐仓和杠杆目标来自项目配置/控制面，Adapter 返回只读配置事实并参与对账。
当前共享 `AdapterRequest` 没有账户配置写入命令，因此本入口不提供修改杠杆、模式或任意 API
透传；设置不同或证明不足保持准入关闭。如需自动配置写入，须先单列通用合同及调用方影响。

epoch 在订阅或接收新连接数据前持久消费。每次 runtime 初始化另持久消费 generation，并从
Owner 已提交游标接续规范事件序列；恢复初始化先重放公共 RawIngress 中尚未应用的尾部，
再创建新 incarnation，不能抢先复用已经捕获但未应用的序号。seal / snapshot / rotate 中断后
完成原检查点再追加，允许跳过已消费 epoch，禁止回退。公共 RawIngress 先记录绑定配置摘要、
generation、完整捕获元数据与 decoder 序列的 header，再保存原始字节；两者缺一或配置不匹配时失败关闭。
`MarketReplay` 只从这些证据重建并经 Owner 应用，没有 transport 或签名资源。
epoch stream 保留已登记的八个品种高水位；更换全部品种并耗尽槽位时须显式迁移，不能重置。
配置或环境切换须先用原批准配置完成旧流回放，再选择新捕获流；不能拿新配置解释旧流。

策略继续使用原有双 IOC 与 Maker–Taker 状态机。`InstrumentRules.quote_asset` 必须相同；
永续的该字段必须绑定实际 settlement Asset。包装现货可在冻结规则中提供
`approved_base_pair=(economic_asset, approval_ref)`；配置审批必须证明原子单位相同且为 1:1
经济敞口。`base_asset`、实际费用与账本身份不变；扫描、数量匹配与评估只在经济敞口比较时
使用批准身份。批准引用进入配置/checkpoint 与评估摘要；未配置时既有摘要保持原样。

现有入口可直接验证，均无网络或真实凭证：

```powershell
zig build run -Doptimize=ReleaseSafe -- --hyperliquid-offline
python tools/zig-entry.py test src/testing/acceptance/venues/hyperliquid_execution_acceptance.zig -O Debug --test-filter Hyperliquid --stack 67108864
python tools/zig-entry.py test src/testing/acceptance/venues/hyperliquid_execution_acceptance.zig -O ReleaseSafe --test-filter Hyperliquid --stack 67108864
zig build strategy-authority-probe -Doptimize=ReleaseSafe
python -m unittest discover -s python -p test_strategy_instance.py -k hyperliquid
```

Web/package 验证复用现有 authority probe 的 `hyperliquid` 离线模式及原有认证协议，
不新增控制面。对手为 SimulatedVenue；两腿准入、发送故障与恢复证据不能替代真实跨所成交。
Linux production dispatcher 目前仍仅提供模拟生命周期，Windows Demo 节点仍是其既有 OKX
流程；本票没有将离线 probe 冒充在线部署。真实 transport/节点资源装配及真实 Testnet
证据属于后续部署验收；按用户澄清不再作为 08 Adapter 功能验收的前置，生产资格仍关闭。

08 的 Adapter 功能矩阵、公开只读观察与验证证据见
[Adapter 功能验收记录](hyperliquid-testnet-qualification.md)。真实 transport、部署配置、
策略及对手账户不阻塞 Adapter 功能验收；离线通过不表示 Testnet 真实成交或生产资格。
