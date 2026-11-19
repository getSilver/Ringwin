# 扫描目录复用已生效资产登记

日期：2026-11-17。基线 `22ca6eca`；未提交。对应 [06](../../.scratch/settings-driven-scanner/issues/06-integrate-and-retire-static-config.md)。本轮按用户后续确认先实现：移除 BTC／ETH 特殊名单，接通现有资产登记与既有配对器；正式机会评估仍未修复，06 保持 open。

## 行为和边界

`STANDARD_PERP_UNDERLYINGS` 和 `_hyperliquid_asset()` 的特殊共享逻辑已删除。没有迁移名单，也没有按代码同名、大小写或去前缀合并。

已有核心 `AssetRegistry` 的生效定义包含 AssetIdentity、atomic_scale、版本、来源身份／摘要和按 Venue 绑定的代码。新只读投影从核心语义重放的已提交日志前缀提取这些登记，并以已 sealed 的 deployment accounts 确定环境；不修改核心定义或交易权限。活动日志没有 sealed footer 时可以读取其已提交前缀，未完整提交的尾部不激活事实；语义重放错误拒绝提供登记。

正常 Web 组装将已有 `ProjectionProvider.asset_bindings` 交给 ScannerRuntime。动态目录经原 Zig 适配器验证后，按 `(Venue, Environment, exact code)` 查找既有登记，以登记的 AssetIdentity 建立环境隔离的观察身份，再交给原 `arbitrage_scanner.scan()`。不新增配对器、利润算法或用户维护的可信品种文件。

观察层继续采用既有固定 18 位规范观察单位，原生资产精度和出处单独保留；tick、lot、合约乘数沿现有适配器及 `_entry()` 的精确有理数换算，不修改核心账本单位。明确登记的等单位别名可复用身份；没有明确登记的包装／缩放名称不会继承普通资产身份。

同一资产编号的定义版本、来源和单位冲突会拒绝登记快照；不同核心定义不能因为数值编号碰巧相同而合并。重复日志投影的不同激活 barrier 可去重，输入及文件顺序不改变关联摘要。真实公共 transport 拒绝 `test_fixture` 资产来源。

**必要边界：这项修复复用已有登记，不会从 Hyperliquid meta 推导出尚未登记的跨所身份。** 未供应 ProjectionProvider、没有可重放的生效登记、deployment 未 sealed 或具体品种缺少代码绑定时，品种仍能被发现，但保持来源隔离、不形成未经依据的跨所配对。缺项按品种记录在来源状态的 `asset_binding_gaps`。这不代表原始需求中所有动态资产的自动身份接入问题已经解决。

只读供应复用既有 projection probe，增加 `assets` 模式；不要求公共行情拥有私有交易凭证。该模式当前支持单文件不超过 16 MiB、可由现有核心重放器恢复的 `shard-*.journal`。超容量、缺少必要历史或重放错误均失败关闭，不使用旧登记掩盖错误；没有新增跨 segment／snapshot 恢复实现。

## 范围、缓存和失效

登记摘要变化时先撤销旧观察和候选，再重新发现受影响来源；缓存保留每个角色的原始绑定及来源证据。旧缓存刷新前不能发布新健康观察；恢复时校验新关联身份和环境。include/exclude 和 quote 筛选按来源代码重绑，已经存在的相同身份直接保留，避免别名目录换序改变范围。

关闭“纳入新品种”时原 registered 集合不因关联变化扩大；其他消费者仍保留订阅所有权，登记变化期间撤销旧输入。历史扫描输入已冻结具体规则及身份，沿原归档／重放接口读取，不重写历史身份。新品种策略、目录 refresh／TTL、退市和部分写入恢复沿用既有流程。

## 确定性证据

```powershell
python -c "import sys, unittest; sys.path.insert(0, 'python'); unittest.main(module=None, argv=['unittest', 'test_scanner_assets', 'test_scanner_integration', 'test_arbitrage_scanner', 'test_hyperliquid_pairing'], verbosity=1)"
```

最终 **83/83 通过，119.129s**。包含：

- SOL、DOGE 两个原名单外品种：实际登录／HTTP 设置与范围 → Python discovery／poll → 原 Zig worker／RawIngress／规范盘口 → 现有扫描器，各形成 3 个候选。每个 worker 的审计均为 3 captures。登记及外部协议输入明确为合成 fixture，不是在线身份资格或经济评估通过。
- 同名不同已登记资产不配对；未登记 BTC 无例外；未登记 kSOL 不去前缀继承 SOL；既有包装资产与错误单位检查保持隔离。
- 显式等单位别名、登记列表换序和重启保持身份；原生 universe 换序、环境隔离及重启默认停止继续通过。
- 登记变更撤销旧候选，保留 registered 与筛选；新品种开关、范围过滤、部分写入后保存既有设置恢复、TTL、源失败隔离和其他消费者订阅回归继续通过。
- 既有直接评估一致性与包装配对校验继续通过；本轮没有接通正式运行的评估输入。

首次扩展运行 82 项有 1 个失败：组合 transport 的测试未标记合成来源，被新资产来源校验正确拒绝。已在该测试声明 `synthetic_protocol_fixture`，单项复验及上述最终全组通过；没有放宽真实 transport 的准入。此前缓存迁移夹具也补回其历史格式不含新关联字段的事实。

```powershell
python tools/zig-entry.py test src/runtime/control_projection.zig -O ReleaseSafe --test-filter 'read-only asset projection' --stack 536870912
python tools/zig-entry.py build-exe src/testing/integration/control_projection_probe.zig -O ReleaseSafe '-femit-bin=.scratch/build/scanner-gap-verification/asset-projection.exe' --stack 536870912
```

定向 Zig 测试 **2/2**（含 entry 包装测试）通过；验证核心已激活 SOL／DOGE 登记保留原身份、单位、来源摘要和环境，以及未 sealed 部署不输出代码绑定。projection probe 构建通过。语法检查、Zig 格式和 `git diff --check` 通过。

另以构建后的真实 probe `dump` 生成既有核心 genesis 日志，经 Python `ProjectionProvider.asset_bindings()` → native `assets` 语义重放验证：未 sealed 部署返回空登记且可重复读取；将同文件改为损坏字节后，供应拒绝，未返回此前缓存。此探针验证读取链路与失败关闭，不是生产登记来源资格。

未运行全量 Python／Zig、页面浏览器或在线行情验收；未读取凭证、下单、提交、推送或部署。SOL／DOGE 形成候选仍显示现有 missing_evidence，不代表正式评估器已经接通。当前代码没有扩大交易权限。
