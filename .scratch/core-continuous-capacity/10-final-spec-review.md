# 10 Final Spec review

2026-10-16；基线 `4ea4c3ee3f6bfc4a822196649fb011e3b5f0dfa2`。只读复核源码与证据，未运行测试。114份源码SHA256 `73532d4ae117f849e083011cde02b169d8862b457c1e8f362e40571b31492bce`；逐文件核验0 mismatch。producer以 `10-final-v1-identity.json:18` 六份脚本完整SHA为身份，逐份核验0 mismatch；其中final runner `2f75711cf091a4f3a60be9f121eba217d913575b0ec50697dfc4ea87bc5a303d`，process runner `7b3d9424e919588eac6211d783ee61abb3a3e56b77d49515dfc181721c612255`，audit `6e33f67b1470aff5bc698a04392095c8a0aef5653a103fc8d3e8c7eca85f4a95`。

## (a) 缺失／部分要求

无剩余确认P1/P2。原scope P2已关闭：issue10:19要求“Windows真实FileAdapter运行票09的小规模公共业务链”，capacity-contract:144要求“同一fixture接真实文件adapter、子进程重开”。`src/windows_observation_file_acceptance.zig:61` 从bootstrap即使用File与同一公共业务helpers；`:133`起实际核对500唯一组合、75/50产品、完整命令归属、持久ClientOrderId及funding/cross方向。`src/windows_capacity_acceptance.zig:312`真实两品种开平/hedge，`:449`核对混合状态，`:561`接File共享账户Coordinator。`run-10-file-processes.py:346`实际另启observation seed/recover。已读取同源码 `10-preflight-v2` 的12进程成功记录：1轮混合/共享账户归档及恢复、精确before/after kill恢复、真实500 seed108发送/recover0发送；不再仅依赖09内存结果。

## (b) 多余范围

未确认。夹具各自仍≤100 live/terminal；小规模结果没有授予千单、压力、预算或平台生产资格。`10-evidence.md`明确目录flush失败与断电耐久性限制，符合issue10:22–23。

## (c) 看似实现但错误

未确认P1/P2。`src/durable_store.zig:1643`只将双sidecar首次缺省视为Unavailable；已发布缺objects仍关闭，Coordinator绑定旧history_root时也拒绝Unavailable。共享summary采用独立连续publication序列，未冒充Shard权威barrier。

最终验收仍未完成。`audit-10-final.py:58`起要求同源完整Debug/ReleaseSafe与18故障场景，`:112`起要求每artifact十轮/30新进程、完整authority、日志/产物身份及物理文件恢复不变。该计划足够覆盖当前小功能范围；必须等实际最终退出码与audit通过后才可关闭票。当前预检不替代最终全套。
