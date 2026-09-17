# 图表技术选型研究

Type: research
Status: closed
Label: wayfinder:research

## Question

为零构建本地 Web 分析界面选定图表技术方案。需回答：

1. uPlot 单文件 vendored 的可行性：实际体积（gzip 后）、许可证、浏览器兼容、
   是否依赖构建工具；ES module / UMD 引入方式各是什么。
2. 替代品对比（至少覆盖）：Chart.js 单文件版、ECharts 按需裁剪是否可行、
   纯手写 SVG 折线图的成本上限。对比维度：体积、权益曲线+回撤区域填充的
   表达力、时间轴处理、交互（缩放/hover 十字线）、零构建集成难度。
3. 结论：给"权益曲线 + 回撤 + 按策略归因堆叠图"这一组需求一个首推方案与
   一个兜底方案，附引入代码示例（`<script>` 或 ES import 均可）。

产出写入 `research/01-charting-tech.md`（相对本票目录）。

## Answer

已完成（2026-08-24），全文见 [research/01-charting-tech.md](../research/01-charting-tech.md)（体积为 jsDelivr 官方 dist 实测）：

**首推 uPlot 1.6.32**（MIT，2025-03 release，维护活跃至 2026-04）
- `uPlot.iife.min.js` = 51 KB min / **22 KB gzip** + 0.9 KB CSS；单文件 IIFE 全局 `uPlot`，另有真 ESM 版
- 内置时间轴刻度分级、无日期库依赖、十字线 + legend 联动；回撤区域用 `series.fill`/`fillTo` 一行配置
- 唯一代价：堆叠柱状无原生 `stacked`，需几行 reduce 预累加

**兜底 Chart.js 4.5.1**：UMD 单文件 208 KB / 70 KB gzip，堆叠最好用，但时间轴需外挂 date adapter。

**排除**：ECharts（零构建下最小版 ~158 KB gzip 且 tree-shaking 依赖打包器）；手写 SVG（十字线对齐+缩放约 600–1500 行自维护代码）。

两份可直接内嵌的引入示例（IIFE/ESM 权益曲线+回撤、UMD 归因堆叠柱状）附报告末尾。
