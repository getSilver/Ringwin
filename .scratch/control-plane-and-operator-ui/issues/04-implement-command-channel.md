# 实现签名命令注入通道

Type: task
Status: closed
Resolution: 已实现并通过全部测试；见下方 Answer
Assignee: ox-alpha (本会话)
Blocked by: 03
Parent: [构建最小控制面与管理操作界面](../map.md)

## Question

按 03 号冻结设计实现命令注入通道：TCP 主通道、紧急投递目录、kill_switch 命令种类、
幂等/过期/MAC/版本前置单测与重放等价。

## Answer

已实现（2026-08-23）：

**Zig 侧**
- `src/control_channel.zig`（新模块）：签名信封编解码（u8 版本 + HMAC-SHA256 + 106 字节
  规范命令区，字段顺序与分片 control_command codec 一致）、确定性 content_hash
  （SHA-256 前 16 字节）、常量时间 MAC 校验、过期预检、按 target 路由的 Router、
  `pullOnce` localhost TCP 拉取（长度前缀帧 + 零长终止符）、`drainDropDirectory`
  紧急目录排空（接受后改名 `.done`，拒绝文件留档审计）。
- `src/operational.zig`：新增 `CommandKind.kill_switch` 与 `GateReason.operator_kill`
  （均为尾部追加，既有 codec 整数值不变）；转移规则 = 锁存 referenced_latch_identity、
  撤销交易授权、撤销全部挂单；仅 `resolve_latch` 可解除。
- `src/control_plane_probe.zig`：验收探针宿主，双分片 bootstrap 后经 TCP 或目录
  注入命令，输出稳定摘要行。

**Python 侧**
- `python/control_plane.py`：逐字节兼容的信封签名（含 u128 双 Q 拆分）、帧封装、
  单客户端拉取服务。
- `python/emergency_kill_switch.py`：紧急控制台，写临时文件 + fsync + 原子改名投入。
- `python/verify_control_plane.py`：三阶段失败即停验收（TCP 全轨迹 / 坏 MAC /
  紧急目录），输出 `control_plane_channel_acceptance=passed`。

**测试结果**
- `zig test src\control_channel.zig -O ReleaseSafe`：91/91 通过（含信令篡改、错钥、
  过期、content_hash 绑定破坏、跨分片拒绝、重复幂等、双分片镜像重放摘要一致、
  真实 localhost TCP 回环、临时目录排空）。
- `zig test src\main.zig -O ReleaseSafe`：108/108 通过；`zig run src\main.zig` 四条
  轨迹摘要稳定。
- `python python\verify_control_plane.py`：
  - tcp_phase：accepted=2 duplicate=1 expired=1 rejected=1，authority_100=true、
    authority_200=false；
  - bad_mac_phase：坏 MAC 拒绝且好命令照常生效；
  - emergency_dir_phase：紧急 kill 经目录生效，authority_100=false。

**边界说明**
- 紧急控制台密钥文件当前为开发 fixture（32 字节原文或 hex）；CredentialStore 口令
  解锁在生产化波次接入，已在票内声明。
- README 的 happy_path 摘要行与本票无关且早于此变更即已过时，留给 10 号关闭票处理。

## Comments

- 2026-08-23：实现完成，全量回归通过，票关闭。
