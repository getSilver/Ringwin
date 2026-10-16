# 10 v2 Spec review

2026-10-16；基线 `4ea4c3ee3f6bfc4a822196649fb011e3b5f0dfa2`。当前114源码SHA256 `c29cba9ae0f97a53820b71401040ae1e0c8e0662c990e0c1a94683170c247885`。独立只读复核，不运行测试，不修改源码或producer。

## (a) 缺失／部分要求

无新增确认P1/P2。issue10:19“Windows真实FileAdapter运行票09的小规模公共业务链”和capacity-contract:144“同一fixture接真实文件adapter、子进程重开”的源码范围已补齐：`windows_observation_file_acceptance.zig:61`真实File承载500唯一组合及三类别，`windows_capacity_acceptance.zig:312`真实mixed开平/hedge，`:561`四Portfolio共享账户File Coordinator；新process恢复保留完整authority及物理文件比较。当前v2实际全套/十轮结果仍pending，不能沿用v1各623通过；v1真实64MiB advance02失败已否定其整体验收完成。

## (b) 多余范围

未确认。`demo_authority.zig:576`与`trading_shard.zig:1580`只将大candidate事务移入noinline私有helper，直接服务issue10文件公共业务链实际64MiB进程可运行性；未增加生产容量或栈预留，不改变权限、身份、归档合同。

## (c) 看似实现但错误

未确认P1/P2。Owner外层历史查证/容量守卫仍先执行，helper保留完整候选、append/commit成功后才发布及失败关闭；Replacement外层先判无候选/禁止新发送，helper保留原qualification、风险证据和copy-back顺序。原rollback未删改，未通过清空历史或关闭校验规避失败。此前Store首次双sidecar缺省修复仍保留已发布缺段失败关闭。

`run-10-final-acceptance.py:91`先构建并跑app/CLI真实十轮，再完整两模式；`:63`每次执行绑定构建SHA，`audit-10-final.py:90`将封存artifact反核build结果，符合issue10:21身份义务。必须等v2实际终态后更新本报告；无静态结论可替代进程栈/恢复验收。

## Producer identity

SHA256，按本次读取绑定：

- run-07-command.py `9a248c655a81666d0208a787868d5dd0ec28fbb8aac764643bd6898110352d14`
- run-10-command.py `67232ef1c8639207199a6f6dae76b1463131934d2162e2ddc8d8792b861fe9b8`
- run-10-final-acceptance.py `d8fdc7b6b0aab683e5d3a1a09651705ae8cf4baf69e4c0aa3347f23f11c317e1`
- run-10-file-processes.py `7b3d9424e919588eac6211d783ee61abb3a3e56b77d49515dfc181721c612255`
- audit-10-final.py `218b63279c6e5ac57a0befb80f7ea8337503e54382d468e2034eaf40b9863272`
- collect-10-host.ps1 `7c85079d24bd1123cfa88c31871fdcb1a3567d2e49fd1bc6b9c2819f757eab7f`
