# 图表库选型研究：零构建量化分析 UI

- 日期：2026-08-26
- 场景：本地单用户、零构建（无 node/npm）、纯静态 HTML+JS 的策略分析界面
- 图表需求：权益曲线（line）、回撤区域填充图（area fill）、按策略归因的堆叠柱状/面积图、时间序列 hover 十字线与缩放
- 方法：所有体积数据为本次实测——直接从 jsDelivr 下载官方 dist 文件，用 PowerShell + GZipStream(Optimal) 本地测量；版本与日期取自 GitHub Releases / dist 文件头注释。

## 背景与约束

1. **零构建**：不允许 npm/webpack/vite；库必须以单个 JS 文件 `<script src>` 或原生 ESM `import` 引入即用。这意味着"tree-shaking 后最小包"类方案（ECharts `echarts/core`）不可行。
2. **时间序列为主**：X 轴是 UTC 时间戳，需要合理的自动刻度、缩放后重算刻度、hover 对齐到最近数据点。
3. 数据点规模：日级权益曲线为千点级，分钟级可达十万点级——Canvas 渲染优于 SVG。
4. 单文件引入时，任何"核心包之外还需要 adapter/plugin 文件才能用时间轴"的成本都要计入集成难度。

## 实测体积（2026-08-26，jsDelivr 官方 dist）

| 文件 | 原始 min 大小 | min+gzip |
|---|---:|---:|
| uPlot@1.6.32 `uPlot.iife.min.js` | 51,081 B | **22,277 B (~21.8 KB)** |
| uPlot@1.6.32 `uPlot.esm.js`（ESM 版，未再压缩） | 145,423 B | — |
| uPlot@1.6.32 `uPlot.min.css` | 1,857 B | ~0.9 KB |
| chart.js@4.5.1 `chart.umd.min.js` | 208,522 B | **71,374 B (~69.7 KB)** |
| echarts@5.6.0 `echarts.min.js`（完整） | 1,034,102 B | 339,225 B |
| echarts@5.6.0 `echarts.common.min.js` | 664,311 B | 222,184 B |
| echarts@5.6.0 `echarts.simple.min.js` | 469,733 B | 157,921 B |

## 候选对比表

| 维度 | uPlot 1.6.32 | Chart.js 4.5.1 | Apache ECharts 5.6.0 | 纯手写 SVG |
|---|---|---|---|---|
| 许可证 | MIT | MIT | Apache-2.0 | — |
| 零构建可用体积 (min+gzip) | **~22 KB** (+0.9 KB CSS) | ~70 KB | 最低 simple 版 ~158 KB；tree-shaking 需打包器，**不满足零构建** | 0 KB 库，但自写代码 |
| 单文件 IIFE / 全局变量 | ✅ `uPlot.iife.min.js` → 全局 `uPlot`，无依赖 | ✅ UMD → 全局 `Chart`，无依赖 | ✅ → 全局 `echarts`，无依赖 | ✅ |
| 原生 ES Module 引入 | ✅ `dist/uPlot.esm.js`，`export { uPlot as default }`，可直接 `import uPlot from './uPlot.esm.js'`（实测确认导出形式） | ⚠️ dist 仅 UMD；ESM 路径面向打包器 | ⚠️ dist 仅 UMD/IIFE | ✅ 自控 |
| 内置时间轴 | ✅ 专用 time scale，内置多粒度刻度格式化，无 moment/luxon 依赖；支持时区（`tzDate`）；DST 处理于 2025-08 重写 | ⚠️ time scale 需要**外部 date adapter**（luxon/date-fns/dayjs），UMD 包不含 → 零构建下要么加第二个文件，要么退化为 category 轴 | ✅ 内置 time 轴 | ❌ 全部自己写 |
| 权益曲线（line） | ✅ 核心，专为时间序列设计 | ✅ line dataset | ✅ line series | 可写 |
| 回撤区域填充 | ✅ series `fill`（fillTo/to/below 等），负值区域天然支持 | ✅ Filler 插件内置（`fill: true`），支持 origin/base | ✅ areaStyle | 手写 polygon，简单 |
| 堆叠柱状/堆叠面积 | ⚠️ 无 `stacked:true`；需自行预累加数据（官方 demo 即此模式），bar paths 支持 barWidth 百分比 | ✅ 原生 `stacked: true`（柱状与面积均支持） | ✅ 原生 stack | 手动累加，中等 |
| hover 十字线 + 多系列联动 tooltip | ✅ 内置 cursor + legend 联动，性能极好 | ✅ tooltip interactionMode 'index'，好用但大数据量偏慢 | ✅ axis tooltip，功能最强 | ❌ 全部自己写（约占总成本一半） |
| 缩放/平移 | ✅ 官方 wheel-zoom 插件（仓库内 demo 级插件，非 core 内置，约几十行，可直接拷贝进页面） | ✅ chartjs-plugin-zoom（额外一个文件） | ✅ dataZoom 内置组件 | 自己写 wheel/drag 逻辑 |
| 大数据量渲染 | Canvas，10 万点级别公认最快之一（Grafana 用它替换 Flot） | Canvas + decimation 插件，万点级尚可 | Canvas/ZRender，中等偏重 | SVG 在数万点会卡 |
| 维护活跃度 | 活跃：最后 release 1.6.32（2025-03-14），master 持续有提交至 2026-04（实测 commits 页），~10.4k stars | 活跃：v4.5.1（2025-10-13，GitHub Releases 签名发布） | 极活跃：Apache 顶级项目 | N/A（自己维护） |

### 各候选关键事实出处

- **uPlot**：MIT（dist 文件头 "All rights reserved. (MIT Licensed)"，Leon Sorokin）；release 1.6.32 见 [GitHub Releases](https://github.com/leeoniya/uPlot/releases)；ESM 导出与 IIFE 全局变量均为本次下载实测；时间轴内置、无日期库依赖见[官方 README](https://github.com/leeoniya/uPlot)。
- **Chart.js**：v4.5.1 于 2025-10-13 发布（[Releases](https://github.com/chartjs/Chart.js/releases)）；官方安装文档明确"clone 仓库必须自行构建才有 dist"，推荐 CDN/GitHub release 拿预构建 UMD；time scale 需 date adapter 为官方文档结论（[docs: time scale](https://www.chartjs.org/docs/latest/axes/cartesian/time.html#getting-started)）。
- **ECharts**：tree-shaking API（`echarts/core` + `echarts.use([...])`）明确依赖 npm + webpack 等打包器（[官方 handbook: Import ECharts](https://echarts.apache.org/handbook/en/basics/import/)）→ 与零构建约束冲突；三个预构建 dist 的体积为本次实测。

## 首推方案：uPlot

理由：

1. **唯一同时满足全部硬约束且体积最小的选项**：~22 KB gzip 单文件 + 0.9 KB CSS，MIT，IIFE 与 ESM 双形态，时间轴零依赖。
2. 三种目标图表全覆盖：line/fill 是其核心能力；回撤图用 `series.fill` 一行配置；堆叠柱状虽需预累加数据（几行 reduce），换来的是极轻的运行时。
3. 十字线 + legend 数值联动开箱即用，这是权益曲线交互的核心诉求；缩放用官方 wheel-zoom 插件源码（MIT，可整段内嵌）。
4. Grafana 生产验证，长期维护风险低。

已知取舍：API 偏底层（options 较长）、堆叠需手动累加、审美朴素（CSS 可定制）。

## 兜底方案：Chart.js（UMD 单文件）

适用条件：如果开发中发现 uPlot 的底层 API 成本过高、或后续需要饼图/雷达等更多图表类型。代价是体积 ×3，且若要真正的时间轴需追加一个 date adapter 文件（如 dayjs adapter，~2–3 KB gz + dayjs 本体），或接受 category 轴 + 自格式化标签。

## 引入示例代码

### 首推：uPlot（IIFE script 标签版）

```html
<!-- 从 GitHub Release 或 jsDelivr 下载后放到本地 lib/ 目录 -->
<link rel="stylesheet" href="lib/uPlot.min.css">
<div id="equity"></div>
<script src="lib/uPlot.iife.min.js"></script>
<script>
  // xs: [t0, t1, ...] 秒级 Unix 时间戳；ys: 权益值
  const xs = [1690000000, 1690086400, 1690172800];
  const ys = [10000, 10250, 9980];

  new uPlot({
    title: "Equity Curve",
    width: 800, height: 300,
    scales: { x: { time: true } },
    series: [
      {}, // x 轴占位
      {
        label: "Equity",
        stroke: "#06c",
        width: 2,
        fill: "rgba(6,108,204,0.15)",   // 权益线下方淡填充
        value: (u, v) => v == null ? "--" : "$" + v.toFixed(2),
      },
    ],
    axes: [
      { values: [                       // 时间轴刻度按跨度自动分级
          [3600, "{HH}:{mm}"],
          [86400, "{MMM} {DD}", null, null, "{MMM} {DD}\n{YYYY}"],
        ] },
      {},
    ],
  }, [xs, ys], document.getElementById("equity"));
</script>
```

### 首推：uPlot（原生 ESM 版）

```html
<link rel="stylesheet" href="lib/uPlot.min.css">
<div id="drawdown"></div>
<script type="module">
  import uPlot from "./lib/uPlot.esm.js"; // export { uPlot as default }

  const xs = [1690000000, 1690086400, 1690172800];
  const dd = [0, 0, -2.65];               // 回撤 %

  new uPlot({
    width: 800, height: 220,
    series: [
      {},
      {
        label: "Drawdown %",
        stroke: "#c33",
        fill: "rgba(204,51,51,0.25)",
        fillTo: 0,                        // 填充到 0 基准线 → 回撤区域图
        points: { show: false },
      },
    ],
  }, [xs, dd], document.getElementById("drawdown"));
</script>
```

> 注：`uPlot.esm.js` 未压缩（145 KB），零构建场景建议生产使用 `.iife.min.js`；ESM 版适合想要模块化组织代码时的开发体验。二者 API 完全一致。

### 兜底：Chart.js UMD

```html
<canvas id="attribution" width="800" height="400"></canvas>
<script src="lib/chart.umd.min.js"></script>
<script>
  // X 轴用 category + 预格式化标签，规避 time scale 对外部 date adapter 的依赖；
  // 若愿意多引一个 adapter 文件，则改用 type:'time'。
  new Chart(document.getElementById("attribution"), {
    type: "bar",
    data: {
      labels: ["2026-07", "2026-08"],
      datasets: [
        { label: "Momentum", data: [320, 410], backgroundColor: "#3b82f6" },
        { label: "MeanRev",  data: [-80, 150], backgroundColor: "#f59e0b" },
      ],
    },
    options: {
      responsive: false,
      scales: {
        x: { stacked: true },             // 堆叠柱状：一行配置
        y: { stacked: true },
      },
    },
  });
</script>
```

## 结论速览

- **首推 uPlot 1.6.32**（MIT，~22 KB gzip）：体积、时间轴能力、十字线/缩放交互与零构建契合度全面领先；堆叠图需手动累加数据是唯一小代价。
- **兜底 Chart.js 4.5.1**（MIT，~70 KB gzip UMD）：API 最友好、原生堆叠；代价是体积 ×3 且真时间轴需外加 date adapter。
- **排除 ECharts**：零构建下最小仍 ~158 KB gzip，tree-shaking 依赖打包器。
- **排除纯手写 SVG**：十字线对齐、缩放重绘、时间刻度分级三项合计约 600–1500 行自维护代码，仅在没有第三方代码审计要求时才值得。
