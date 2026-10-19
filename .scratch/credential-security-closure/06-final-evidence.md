# 凭证安全修复最终离线证据

最终业务源码 SHA256：`81bffb6dab6f22ad14feea2e99d520e7365b2900a60dc2b5d253228a4b7ee0ae`。
实现修复截至 `040a21a2`；之后提交为回归、格式属性与证据元数据。

[最终清单](credential-final-v3-validation.json)绑定35个阶段的精确命令、源码/编译器/producer/依赖/日志/16个产物身份及原始结果；[冻结计划](credential-final-v3-plan.json)和[持久状态](runs/credential-final-v3/state.json)均保留。最终35/35阶段exit0，所有阶段源码一致，无panic、timeout或源码漂移。v1/v2只在历史证据行尾检查处停止，未进入编译或全量测试；失败原件保留，未重标为成功。

| 验收 | 实际结果 |
| --- | --- |
| Windows 完整 Debug | 650/650，5439.8秒，exit0 |
| Windows 完整 ReleaseSafe | 650/650，2769.3秒，exit0 |
| 两个完整测试程序 | PE stack reserve各512MiB，实际构建后直接运行 |
| Windows入口构建 | app、Windows Demo、独立live acceptance、private smoke均通过 |
| 合成传输 | C request故障矩阵及auth→TransportOwner→C/HTTP拒绝回归通过；无网络 |
| Windows实际离线入口 | fixture、凭证store准入、五角色进程链均exit0；准入只读、send=false |
| WSL Linux ReleaseSafe | store38/38、KDF9/9、AEAD10/10、auth10/10、guard10/10、input11/11 |
| Linux低额度拒绝 | 默认64KiB memlock子进程1/1，stage拒绝且擦除调用方输入 |
| Linux实际凭证入口 | 原生ELF经WSL执行exit0，ready/read_only/send=false |
| Linux独立curl根入口 | 仅语义交叉编译通过，不声称链接或运行Linux curl可执行文件 |

Windows为10.0.17763；Linux为WSL1 `4.4.0-17763-Microsoft`。成功native子进程只在自身设置64MiB memlock并降到uid/gid1000，未改系统配置；默认进程额度仍64KiB。具体主机与保全信息见[记录](06-host-and-preservation.json)。固定编译器为Zig `0.17.0-dev.315+5b647b792`。

## Standards

独立报告确认一项P2：共享Process helper未发布当前退出码，导致长verify脚本读取未初始化/陈旧的`LASTEXITCODE`。[原报告](06-review-original-standards.md)保留。三行修复由唯一review fixer提交`040a21a2`；[独立复核](06-review-followup-standards.md)确认关闭且无增量回归。重复密码读取包装是正确显式owner的可选非阻塞建议，本轮保留，未扩大安全重构。

## Spec

[独立报告](06-review-original-spec.md)确认同一个P2，未确认其他实质遗漏或scope creep；[复核](06-review-followup-spec.md)确认关闭。Windows失败后验在角色终止后、Linux失败后验在紧急清理后执行，凭证及transport owner保持存活。两轴各1项P2、共同指向同一缺陷，现均关闭；无剩余确认P1/P2。

[修复回归](06-review-resolution.md)保留5个原红与5个green公共进程/实际verify前缀用例、四wrapper成功及四旧EnvFile拒绝用例。只使用合成凭证，长verify前缀被fake compiler在fmt处受控终止，完整测试结果由本次35阶段另行取得。

## 保全、清理与范围

八个实现工作树已保全至 `D:/github/Ringwin-credential-worktrees-archive-20261019/`，共33837文件、4453649090字节，逐文件复制后哈希一致；原中断恢复备份另行保留。清理前再次核对原件/副本、提交祖先关系、tracked clean和明确绝对目录，结果见[清理日志](06-cleanup-state.json)。分支和提交保留；集成分支保留，main与其他控制面工作树不变。

八份原件/归档全部核对后，清理状态已为`complete`，八个实现工作树已移除，分支与提交保留。首次清理启动在PowerShell5.1缺少Get-FileHash处、创建journal及删除前停止；原始错误保留，随后使用已核实具备该命令的PowerShell7.5.4完成核对与清理。

没有读取真实凭证、运行Venue请求/订单、部署或新增生产发送准入。WSL只提供功能证据；目标机dump/swap/掉电、编译器隐式临时/寄存器、TLS/OS内部缓冲及生产资格仍不由本轮证明。
