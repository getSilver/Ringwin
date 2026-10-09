# 01 合同冻结证据

日期：2026-10-09。状态：待合同与容量矩阵审查；不是容量实现验收。

## 来源

- 业务源码基线：`9f47ae6f8d06d5c43a9ac32f0267529739911924`。
- 独立工作树：`D:/github/Ringwin-core-continuous-capacity`；分支：`codex/core-continuous-capacity`。
- `3d130d1b9b07ecb061ccdef79a26eca9fc8b4822` 仅导入用户提供的十二票地图、相关 CONTEXT 变更及 ADR 0010；没有修改业务源码。
- 当前 journal/state/schema registry 为 `30/34/28`，canonical schema 为 `10`。后续合同提出的版本不等于已启用版本。
- 用户本次 implement 请求授权本地实施，取代地图中 2026-10-08 的计划阶段限制；仍不授权网络交易、部署或远程故障。

## 已执行检查

在上述工作树使用 `0.17.0-dev.315+5b647b792`：

```powershell
zig test src/main.zig -O Debug
zig test src/main.zig -O Debug --stack 67108864
```

首条命令在第四个测试的 snapshot restore 路径发生 Windows stack overflow，原始结果保留于
[baseline-debug.log](baseline-debug.log)。第二条仅改变测试可执行文件栈预算，424/424 通过，
见 [baseline-debug-64m.log](baseline-debug-64m.log)。未修改源码以隐藏这个限制。

这些结果证明本次容量工作开始前的回归基线可运行；不证明千单、历史归档、磁盘保留、
Windows/Linux 容量或任何生产资格。64 MiB 也是后续布局、复制与栈测量需要单独记录的运行参数。

## 完成审计

合同与矩阵审核后逐项填写票 01；票 02–12 保持未实现。文档链接、容量常量和耗尽调用路径
按当前源码复核。后续每票按自己的公共 seam、故障矩阵和原始结果关闭，不能继承本页测试计数。
