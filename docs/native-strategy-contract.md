# 原生 StrategyDefinition 构建合同 v1

本合同细化[02票](../.scratch/strategy-package-contract/issues/02-native-definition-build.md)，
沿用 [GLOSSARY](../GLOSSARY.md) 与[共同合同](../.scratch/strategy-package-contract/issues/01-package-and-loading-contract.md)。
它交付静态定义及构建清单；09票将其接入共同发布、实例绑定与显式启用。

## 身份与入口

一个非零128位 StrategyDefinition 身份只绑定一份算法、参数/状态合同与兼容元组。
算法、合同或兼容范围改变必须分配新的定义身份；展示名及入口名不能代替身份。
`src/strategy/native_registry.zig` 显式导入实现，登记实际定义；
`native_manifest.zig` 独立声明期望定义。构建必须校验两者完整相等且一一对应，
拒绝缺失/多余注册、任一侧重复身份、零身份和合同不一致。

原生入口是编译期 Zig 模块，按定义身份定位，保留其具体 Config、State 和函数类型；
不是动态符号、Python入口或稳定C ABI。最小定义 `native_observer` 只接收
规范 ReferencePrice 及其 StrategyCursor，更新有界私有计数，不输出 OrderIntent。
它不拥有 TradingShard、账户、投资组合、风险、I/O 或分配器能力。
未来有交易输出的定义必须显式扩展输出合同并经核心现有准入，不得把回调当作授权。

## 参数与状态

Config/State 合同各自绑定非零 schema 身份、正版本与合同文件 SHA-256，
算法文件也绑定 SHA-256。JSON 合同文件是交付字节而非运行时通用schema解释器；
对应 Zig Config/State、create、onReferencePrice 和 validate 是实际执行入口。
输入参数必须显式提供且通过 create 校验；回调拒绝非递增cursor、错误品种/价格及容量溢出，
失败保留原状态。validate 在候选运行前核对状态与配置约束。

本票不序列化原生内存布局，不把原始结构字节当checkpoint；恢复/参数更新的接线须显式
验证定义、配置及状态合同。Keep 仅可在同定义及精确兼容合同下使用；不支持的转换拒绝。
代码替换和 ForwardRollback 使用新 StrategySuccessor + Rebuild，保留经济历史并遵守
责任闭合、持久激活和显式启用规则；没有隐式Migrate。

## 兼容与构建清单

v1只支持固定 Zig 编译器、目标三元组和优化模式下静态编译的 Zig 定义。
兼容元组精确绑定 native API版本、canonical schema、核心 schema registry、journal与state版本；
不声明跨编译器、目标或布局兼容，不在生产节点编译或加载 `.dll`/`.so`。

`zig build` 在 `zig-out/share/ringwin/native-strategies.json` 安装版本1构建清单，
包含定义/入口、算法与schema字节摘要、兼容元组、编译器、目标与优化模式；
其相对二进制路径定位同一安装树的 `bin/ringwin[.exe]`。二进制包含相同的静态注册。
schema的path相对安装树根解析；algorithm_path用于定位构建源码，算法本身静态包含在二进制中。
`zig build native-contract` 或二进制的 `--native-strategy-build-test` 只做显式离线验收，
按身份从 TradingShard 的注册表取得实际入口并执行一次观察，不安装发布或激活实例。
发布组装时二进制与清单必须由同一 ReleaseArtifact 的签名/payload摘要一起覆盖；
该外层覆盖避免二进制哈希自引用。最终制品资格报告外置绑定最终payload摘要，
不能反写构建清单。

Python与原生共用定义/实例/经济归属、不可变交付、精确兼容、失败关闭及核心授权合同。
原生使用静态类型、静态入口与原生构建清单，不复用Python manifest格式、Host API或portable JSON状态编码。
任何构建/离线验收通过都不授予真实交易、部署或平台生产资格。

## 原生发布与运行接线（09）

签名 ReleaseArtifact 使用显式 `payload_format=strategy_bundle_v2`。v1 Python 格式不变；
v2只包含原生二进制、上述构建清单、schema合同和 `strategy-index.json`，不携带解释器、
Python包或动态库。索引 `format_version=2`，每项包含 `definition_identity`、
`manifest_path=share/ringwin/native-strategies.json` 与 `package_manifest_sha256`。
定义按身份升序排列且唯一；索引和构建清单使用现有canonical JSON编码，组装时将构建输出的
排版JSON规范化。每项摘要绑定canonical `{"build":<构建元数据>,"definition":<完整定义>}`；
构建元数据是清单去掉definitions字段后的对象。二进制摘要由签名payload覆盖，避免自引用。
原生二进制单文件上限256 MiB，包总量仍为512 MiB；其余文件维持64 MiB上限。

部署策略须明确提供 `native_build`，与整份构建清单精确相等；发布同时核对编译器和registry。
现有安装器原子安装整树并登记共同目录，安装不授权交易。Web展示runtime，可选择定义预填绑定；
为复用现有role服务的 `current/ringwin` 固定入口，安装视图另从同一签名二进制字节生成
根级 `ringwin` 可执行副本；它与bin入口一同封存并在加载及重新安装时核对，不接受包外启动器。
投资组合、DecisionDomain、配置摘要、账户品种与预算仍由既有绑定合同校验。
节点独立核对实际运行二进制SHA-256、编译器、target、优化模式和全部静态注册，
不调用包内程序来证明身份。节点嵌入方须从实际运行映像取得摘要；缺失即拒绝。

当前只执行已注册的观察入口：在同一节点Writer内创建静态Config/State，对已提交日志中的
有效ReferencePrice调用观察函数并validate。不支持的入口或输出合同拒绝；观察策略不输出订单，
也拒绝外部output帧。Ready前和撤权后均不能经核心增加风险。显式EnableTrading继续使用现有
签名ControlCommand、共同激活屏障及核心SafetyGate，不调用Python加载器或Host API。
共享屏障的会话字段仅用于既有核心准入，不表示创建了Python进程。

首次绑定及Successor使用节点持久提交回调记录VersionActivationEvent；回调的磁盘与热备
保证由现有嵌入方负责。切换沿用DecisionDomain排空、责任闭合、旧实例封锁及Rebuild，
候选在切换前无权，最终屏障消费后停Ready。ForwardRollback通过原签名发布路径安装旧内容，
再创建新身份；仅能选当前二进制已经静态包含的定义，替换运行二进制须走既有节点发布/重启，
不支持动态加载。原生v1未实现参数转换，明确拒绝；不隐式复用Python状态或Migrate。

观察状态只在节点内持有；Web的checkpoint字段是版本化进度摘要，不是原生内存布局或可恢复
私有载荷。无权恢复从完整已提交日志重建并核对持久激活身份，缺少日志起点或完整尾部时拒绝，
不能在新后端上继承原权限。单实例运行容量沿用现有约束；多实例由10票处理。
