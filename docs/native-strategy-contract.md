# 原生 StrategyDefinition 构建合同 v1

本合同细化[02票](../.scratch/strategy-package-contract/issues/02-native-definition-build.md)，
沿用 [GLOSSARY](../GLOSSARY.md) 与[共同合同](../.scratch/strategy-package-contract/issues/01-package-and-loading-contract.md)。
它交付静态定义及构建清单；发布安装、实例绑定、Ready 与 EnableTrading 由09票接通。

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
不能反写构建清单。当前单payload发布器尚不支持这棵安装树；09票负责共同索引与发布接线。

Python与原生共用定义/实例/经济归属、不可变交付、精确兼容、失败关闭及核心授权合同。
原生使用静态类型、静态入口与原生构建清单，不复用Python manifest格式、Host API或portable JSON状态编码。
任何构建/离线验收通过都不授予真实交易、部署或平台生产资格。
