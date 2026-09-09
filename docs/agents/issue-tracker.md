# Issue Tracker：本地 Wayfinder

本仓库的 issue 与 spec 以 `.scratch/<module>/` 下的 Markdown 文件为准，不默认创建或同步
GitHub Issues。需要发布到 GitHub 时，必须由用户明确要求。

## 目录约定

```text
.scratch/<module>/
├── map.md
└── issues/
    ├── 01-<slug>.md
    └── 02-<slug>.md
```

参考实现：`.scratch/trading-core-system-closure/`。

`map.md` 维护 Destination、Definition of done、Rules、Route、Frontier、Decisions so far、
Not yet specified 和 Out of scope。`Route` 使用相对链接指向 `issues/`；`Frontier` 只列出无未完成
blocker 且尚未完成的下一张票。

每张 issue/spec 使用以下头部；没有值的字段保留为空：

```text
# 标题

Type: task
Status:
Assignee:
Blocked by:
Parent: [模块地图](../map.md)
```

正文至少包含 `Question` 与可检查的完成条件；完成后填写 `Answer` 或实现证据，将 `Status` 设为
`resolved`，并同步更新 map 的 Frontier 与 Decisions so far。整个模块完成后，将 map 的 `Status`
设为 `closed`。

## 工作规则

- 创建、读取、分诊、认领、阻塞和关闭均直接修改这些 Markdown 文件。
- 每次只认领并完成一张 Frontier issue；依赖按 `Blocked by` 顺序处理。
- issue/spec 修改前读取同模块 `map.md`、相关 issue、根级 `CONTEXT.md` 和相关 ADR。
- 本地 issue 编号只在所属模块内有意义，引用时使用相对 Markdown 链接，不使用裸 `#42`。
- GitHub Issue、GitHub label 和 PR 不作为本地 tracker 的状态来源。
