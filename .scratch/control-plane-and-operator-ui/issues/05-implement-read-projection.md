# 实现分片稳定日志只读投影

Type: task
Status: closed
Resolution: 已实现并通过全部测试；见下方 Answer
Assignee: ox-alpha (本会话)
Blocked by: 01, 02
Parent: [构建最小控制面与管理操作界面](../map.md)

## Question

控制面侧只读投影：tail 分片稳定日志，用既有 SemanticReplay 路径重建只读视图
（OperationalMode、SafetyGate、EffectiveTradingAuthority、PortfolioPosition、挂单、
对账差异汇总），以 JSON API 暴露给 UI；缺口或未知 schema 显式 degraded 失败关闭。

## Answer

已实现（2026-08-23，工作树 `D:\github\Ringwin-control-plane`）：

**Zig 侧**
- `src/control_projection.zig`（新模块）：`projectJournal` 把整段稳定日志交给核心
  新公开入口 `trading.replayForProjection` —— 与恢复共用同一条 `replayReader`
  SemanticReplay 路径，无第二套解析器。产出有界 `ShardView`（mode、授权、有效权限、
  reduce-only、未决 latch 数、open orders、双层仓位、对账差异、last_sequence、gates
  明细）与 `Outcome` 联合：结构损坏（CRC/magic/序号缺口）、未知 schema、语义重放失败
  一律映射为显式 `degraded` + 原因枚举，degraded JSON 不含任何状态字段。
- `src/trading_shard.zig`：新增 `replayForProjection` 公开重放入口与
  `applyCanonicalGenesis` 公开 genesis fixture 入口（把私有 `startScenarioAuthorized`
  的构造逻辑上提为单一事实源）；`host_gateway` 改 pub 引用。
- `src/control_projection_probe.zig`：探针宿主，三种模式——`demo`（genesis+kill_switch
  与纯 genesis 两份 fixture 日志的 JSON 投影）、`dump`（fixture 日志 hex）、
  `project`（外部 hex 文件投影）。

**Python 侧**
- `python/control_projection.py`：唯一合法的消费方式——调 Zig 探针取 JSON，
  Python 不解码二进制日志。
- `python/verify_control_projection.py`：三阶段失败即停验收。

**测试结果**
- `zig test src\trading_shard.zig -O ReleaseSafe`：87/87；
  `zig test src\main.zig -O ReleaseSafe`：108/108；fmt --check 全绿。
- `python verify_control_projection.py`：
  - demo_phase：被 kill 分片 effective_authority=false、unresolved_latches=1、
    reduce-only=true、lease gates 在场；genesis 分片 authority 保持 true；
  - roundtrip_phase：干净日志投影 status ∈ {complete, truncated_tail} 且 mode=trading；
  - corruption_phase：翻转中段 nibble 后投影显式 degraded，且不泄露任何状态字段。
- 既有 `verify_control_plane.py` 回归仍通过（control_plane_channel_acceptance=passed）。

**边界说明**
- 投影状态 `status=truncated_tail` 反映未封段日志的真实尾态，不视为降级。
- HTTP 服务接线归 08 号票；本票交付的是可被控制面进程直接调用的投影 seam。
- PrimaryLease/fencing 字段的 UI 呈现深度仍是地图 fog，待 07 号原型票定。

## Comments

- 2026-08-23：实现完成，全量回归通过，票关闭。
