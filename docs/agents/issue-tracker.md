# Issue Tracker：GitHub

本仓库的 issue 与 spec 发布到 GitHub Issues。所有操作使用 `gh` CLI；在当前 clone 内运行时由
Git remote 自动确定 `getSilver/Ringwin`。

## 常用操作

- 创建：`gh issue create --title "..." --body "..."`
- 读取：`gh issue view <number> --comments`
- 列表：`gh issue list --state open --json number,title,body,labels,comments`
- 评论：`gh issue comment <number> --body "..."`
- 加标签：`gh issue edit <number> --add-label "..."`
- 去标签：`gh issue edit <number> --remove-label "..."`
- 关闭：`gh issue close <number> --comment "..."`

多行 issue body 使用适合当前 shell 的文件或标准输入方式传递，避免把正文压成单行。

## 技能约定

- 技能要求“发布到 issue tracker”时，创建 GitHub issue。
- 技能要求“读取相关 ticket”时，读取对应 issue、评论和标签。
- Pull Request 不作为 triage 请求入口；如以后需要，可直接修改本文约定。
- GitHub issue 与 PR 共享编号；不确定 `#42` 类型时，先运行 `gh pr view 42`，失败后再运行
  `gh issue view 42`。

## Wayfinder

Wayfinder map 使用一个带 `wayfinder:map` 标签的 issue，子任务使用 GitHub sub-issue；平台不支持
sub-issue 时，在 map body 使用 task list，并在子 issue 顶部写 `Part of #<map>`。

- 子任务类型标签：`wayfinder:research`、`wayfinder:prototype`、`wayfinder:grilling`、
  `wayfinder:task`。
- 阻塞关系优先使用 GitHub native issue dependencies。
- native dependencies 不可用时，在子 issue 顶部写 `Blocked by: #<n>, #<n>`。
- frontier 只包含未关闭、无未关闭 blocker 且未被认领的子 issue。
- 认领任务使用 `gh issue edit <n> --add-assignee @me`。
- 完成研究型任务时，先把结论评论到 issue，再关闭，并把上下文链接写回 map。

GitHub native dependency API 需要 blocker 的 numeric database id，而不是 issue number 或 node id：

```text
gh api repos/<owner>/<repo>/issues/<n> --jq .id
gh api --method POST repos/<owner>/<repo>/issues/<child>/dependencies/blocked_by \
  -F issue_id=<blocker-db-id>
```

## Pull Requests as a triage surface

PRs as a request surface: no.
