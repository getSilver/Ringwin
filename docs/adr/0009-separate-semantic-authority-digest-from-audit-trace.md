---
status: accepted
date: 2026-09-22
---

# 将语义权威摘要与审计轨迹摘要分离

`CanonicalStateDigest` 绑定同一分片屏障的完整 Trace、canonical ingress 及其顺序。这是快照和
恢复的完整性证据，不能为了比较 private order facts 的合法到达排列而弱化。

## Decision

- 保留 `CanonicalStateDigest` 的现有语义，继续作为快照完整性和重放身份检查的唯一摘要。
- 新增 `SemanticAuthorityDigest`，仅在固定 private fact 排列和有界 fuzz 中比较同一事实集合的
  最终 OMS、经济账及相关权威业务状态。
- `SemanticAuthorityDigest` 显式排除 Trace、canonical ingress 游标和仅由到达位置导出的字段；
  其集合型证据按稳定身份归一化后再摘要。
- 该摘要不进入快照元数据、不授权 dispatch，也不作为生产资格或跨版本兼容承诺。

## Consequences

排列测试可以证明合法事实集的业务收敛，同时保留完整、可追溯的输入顺序。任何需要比较新的
private fact 类别时，必须先确认其纳入的状态是否可交换；不能以修改 Trace 或忽略冲突为代价让
摘要相同。
