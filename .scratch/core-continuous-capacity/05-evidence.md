# 05 终态订单与发送证据归档证据

Status: verified-functional

工作树：`D:\github\Ringwin-core-continuous-capacity`；分支：`codex/core-continuous-capacity`。
审查基线：`229330155abdff816dc90cae669c993a606f7863`。
最终89文件源码身份：`85c00368e0bce74b876a6934864911bb810094992434e29e95da7536d975f999`，见[源码清单](05-functional-source-manifest.json)。

2026-10-13用户明确取消千单与容量压力测试，要求全部功能点正确。当前验证按[合同当前执行口径](capacity-contract.md)执行：四分片各25 live及25 terminal（每类合计100），十轮各分片5单结束/归档/补入；500观察组合中100 selected live。生产容量常量未改。本票完成的是订单/发送证据归档功能，不以这些结果授予容量压力或平台生产资格。

## 最终实际结果

| 范围 | 结果 | 原始证据 |
| --- | --- | --- |
| 完整ReleaseSafe功能套件 | 538/538，退出0 | [日志](05-functional-full-releasesafe.log)、[退出记录](05-functional-full-releasesafe.result.json) |
| 同源码完整Debug功能套件 | 538/538，退出0 | [日志](05-functional-full-debug.log)、[退出记录](05-functional-full-debug.result.json) |
| ReleaseSafe/Debug编译 | 均退出0，PE栈各256MiB | [RS构建](05-functional-full-releasesafe-build.result.json)、[Debug构建](05-functional-full-debug-build.result.json)、[产物身份](05-functional-artifacts.json) |
| ReleaseSafe应用构建 | 退出0，实际PE栈64MiB | [构建](05-functional-app-build.result.json)、[产物身份](05-functional-artifacts.json) |
| ReleaseSafe功能CLI构建 | 退出0，实际PE栈256MiB | [构建](05-functional-cli-build.result.json)、[产物身份](05-functional-artifacts.json) |
| 五条golden离线fixture | 退出0，replay等价及恢复检查通过 | [日志](05-functional-cli-fixture.log)、[退出记录](05-functional-cli-fixture.result.json) |
| 纯离线五角色进程链 | 退出0，角色归属/磁盘恢复/快照传递/拒绝错误输入通过 | [日志](05-functional-cli-chain.log)、[负例stderr](05-functional-cli-chain.stderr.log)、[退出记录](05-functional-cli-chain.result.json) |
| Standards/Spec | 未确认具体P1/P2，最新缩小夹具保留全部业务分支 | [审查](05-optimization-review.md) |

RS结束UTC `2026-10-13T14:37:07.6360090Z`，Debug开始UTC `2026-10-13T14:37:09.5288504Z`；两模式串行执行。两份日志各有四条初始驻留、四条初始归档完成和十条四分片替换轮次。第419项最后的OK及全套538/538证明最后四次Owner/Gateway恢复断言完成，不能只以round10输出代替恢复结果。

恢复检查完整CanonicalStateDigest、next_order_id、accepted/uncertain dispatch数量、每条热命令的ClientOrderId及SDK发送计数不增加。每分片最终25 live、零待归档terminal，累计75 terminal；不把这个结果外推为1,024 live能力。

## 可复现命令

编译器：`D:\Program Files\zig\zig.exe`，版本`0.17.0-dev.315+5b647b792`。

```powershell
& 'D:\Program Files\zig\zig.exe' test src/main.zig -O ReleaseSafe --stack 268435456 --test-no-exec -femit-bin=.scratch/core-continuous-capacity/05-functional-full-releasesafe.exe
& 'D:\Program Files\zig\zig.exe' test src/main.zig -O Debug --stack 268435456 --test-no-exec -femit-bin=.scratch/core-continuous-capacity/05-functional-full-debug.exe
cmd /d /c '.scratch\core-continuous-capacity\05-functional-full-releasesafe.exe 1>.scratch\core-continuous-capacity\05-functional-full-releasesafe.stdout.log 2>.scratch\core-continuous-capacity\05-functional-full-releasesafe.log'
cmd /d /c '.scratch\core-continuous-capacity\05-functional-full-debug.exe 1>.scratch\core-continuous-capacity\05-functional-full-debug.stdout.log 2>.scratch\core-continuous-capacity\05-functional-full-debug.log'
& 'D:\Program Files\zig\zig.exe' build -Doptimize=ReleaseSafe
& 'D:\Program Files\zig\zig.exe' build-exe src/main.zig -O ReleaseSafe --stack 268435456 -femit-bin=.scratch/core-continuous-capacity/05-functional-cli.exe
cmd /d /c '.scratch\core-continuous-capacity\05-functional-cli.exe --offline-fixture 1>.scratch\core-continuous-capacity\05-functional-cli-fixture.log 2>.scratch\core-continuous-capacity\05-functional-cli-fixture.stderr.log'
cmd /d /c '.scratch\core-continuous-capacity\05-functional-cli.exe --windows-chain-test 1>.scratch\core-continuous-capacity\05-functional-cli-chain.log 2>.scratch\core-continuous-capacity\05-functional-cli-chain.stderr.log'
```

使用cmd原生文件重定向让测试继承直接文件句柄。短探针已验证：PowerShell管道路径运行中日志为0、退出后补写；直接文件路径在进程仍存活时可读93字节marker，退出0后完整116字节。实际完整功能套件也已验证实时增长。见[诊断记录](05-log-capture-diagnosis.json)及[运行中探针证据](05-log-direct-file-probe.live.json)。临时探针源码/exe/pdb已删除，未修改交易业务或生产日志实现。

## 五项验收映射

| 验收要求 | 实际公共行为覆盖 |
| --- | --- |
| OMS/Gateway完整身份、归档、查证与恢复 | Owner accepted/place-cancel同CID；CCC与多成员真实Owner→Gateway→Adapter链；四分片十轮及Owner/Gateway恢复 |
| 不释放活跃/Unknown/PendingCancel、reservation、引用或窗口未闭合的订单 | OMS及Owner安全资格/缺Fill用例；CCC/predecessor/共享组pin；8单Unknown/PendingCancel及3单安全锁存功能检查 |
| 历史重复无副作用，冲突/超时/缺失失败关闭 | Core认证证明来源/内容/root/epoch/barrier/覆盖绑定；Owner冷重试、原候选时钟、延期admission及重放 |
| 历史发布→Core提交→Gateway回收可恢复 | Store/Owner发布及提交故障、前驱订单补交、孤立未提交尾部保留、高水位及完整文件故障矩阵 |
| CCC/多成员、身份不复用、accepted/Unknown恢复零重发 | 两条真实公共链、四份dispatch各两次正常accepted冷重试、组重复/冲突及恢复SDK不增加 |

## 历史失败与中断保留

旧`3c1d7b91`完整ReleaseSafe为536/537，初始归档返回NoSpaceLeft；这不是完整通过，原日志[保留](05-public-grouped-full-releasesafe-test.log)。共享journal/history配额修复、功能夹具1GiB预算及此前优化历史见[优化记录](05-optimization.md)和审查历史。

原`ea80a6ae`大负载执行按用户请求停止，退出-1，前418/538通过；四分片初始1,024 live/3,600 terminal已断言，分片0完成初始归档、分片1仅到1,024归档，十轮及最终恢复未完成。其[日志](05-final-acceptance-full-releasesafe.log)及[退出记录](05-final-acceptance-full-releasesafe.result.json)完整保留，不记为通过。该源码Debug仅编译、未运行；后续不再自动启动旧大测试。

该05冻结阶段之后，06已按最新小规模功能口径完成，见[06证据](06-evidence.md)；07–12尚未完成。CLI中的production_qualification=false、read_only=not_run、demo_live=not_run保持；本票不部署、不真实下单，不授予资源、索引成本或平台生产资格。

2026-10-14执行口径补充：06复查发现完整套件中的两处旧Gateway夹具仍合成40960 dispatch证明及8192 reservation，虽OMS本身少量订单，也属于用户已取消的大容量证据构造。这一遗漏已在06改为100恢复证明及6 reservation/3 position，生产边界保留纯数字检查。05记录中的538/538是其冻结源码当时实际结果，不能宣称整套没有这两处旧大夹具；最新小规模套件以06的新冻结身份重新验收，不据旧构造授予压力/资源资格。
