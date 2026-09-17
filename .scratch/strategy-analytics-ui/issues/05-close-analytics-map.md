# 关闭策略分析界面地图

Type: task
Status: closed
Assignee: ox-alpha (本会话)
Label: wayfinder:task
Blocked by: 04

## Question

规格冻结后的收尾：

1. CONTEXT.md 词条复查：设计过程中若沉淀出新领域词（如派生数据集的规范名），
   按格式补入；确认未把实现细节混入词条。
2. README 是否需要一行提及（本图只产规格，预计不需要独立章节——给出判断）。
3. 地图收尾：全部票关闭、Decisions so far 完整、fog 清点（每项注明"为何仍是
   fog"）、Status 置 closed。
4. 声明后续候选波次：实现波次的入口条件与规模预估（一段话即可，不展开）。

## Answer

已完成（2026-08-26）：

1. **CONTEXT.md**：无需改动。round-trip 是 AverageCost 既有释放语义（"减仓按比例
   释放成本，反向成交先平旧仓"）的观测输出；分析快照即 DatasetManifest 词条的
   首次落地——规格细节属实现层，不入词表。
2. **README**：不加章节。本图只产规格无可运行能力；等实现波次交付时再写。
3. **地图**：5/5 票闭合、Decisions so far 完整（6 条）、fog 七项逐条注明留档原因、
   Status 置 closed。
4. **后续候选波次声明**：「策略分析界面实现波次」入口条件 = spec.md v1 被批准 +
   核心侧 economics.Projection 观测输出就绪（唯一核心依赖）。规模预估：Zig 探针
   扩展 + Python 编排/快照存储 + 五页前端 + 七条验收断言，约与控制面波次相当；
   可按"投影扩展→数据集管道→页面"切三段推进。

## Comments

- 2026-08-26：地图关闭。

