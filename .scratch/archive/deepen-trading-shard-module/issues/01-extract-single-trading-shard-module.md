# 01 — 提取唯一的 TradingShard 产品模块

**What to build:** 把现有可执行 fixture 内的 TradingShard 提取为唯一、可复用的产品模块，使原生 happy path 与确定性重放继续穿过同一实现，并在迁移期间保持既有可观察结果不变。

**Blocked by:** None — can start immediately

**Status:** resolved

- [x] TradingShard 的权威状态和转换逻辑只保留一份；原有可执行入口只负责组装输入和展示结果，不拥有平行核心。
- [x] 原生成功、失败与重放轨迹继续通过提取后的模块运行，既有稳定事实顺序和固定摘要保持不变。
- [x] 模块对外围调用者隐藏 fixture 组装、日志编码和 Adapter 细节，现有自动回归保持通过。
