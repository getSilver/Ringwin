# 凭证保护修复覆盖清单

此清单连接原始审计、实际业务入口与证据；单票通过不代表最终新源码已经完成全量冻结验收。

| 原问题或迁移约束 | 修复边界 | 当前记录 |
| --- | --- | --- |
| revoked同身份重新stage与旧generation回退 | 首次登记不可覆盖、持久writer锁、认证后代次更新 | 01及03/07公共store回归 |
| Linux TTY回显 | 读取前拒绝TTY；受限pipe/socket路径继续 | 03真实PTY拒绝与管道测试 |
| 超长/未终止口令、畸形已认证payload越界 | 明确错误、调用方原缓冲清零、长度检查 | 03输入/认证畸形payload红绿记录 |
| password/material/plaintext/KEK普通工作区 | 先保护后直接写、指针借用、明确owner释放 | 02 Buffer、03 store、07生产AEAD调用点 |
| Argon2工作区与H0/hash scratch残留 | 固定Argon2/Blake2b窄适配、保护workspace及显式Scratch | 02-v2；首轮仅blocks版本不是最终证明 |
| XChaCha子密钥、ChaCha/Poly1305显式状态 | 固定标量窄适配、保护Scratch、认证失败清输出 | 07 module/integration/native低限额拒绝 |
| HMAC pad/context/schedule/digest及signature | 保护Credentials/SHA256/HMAC/请求owner | 04三模式签名、失败清理与长key向量 |
| C shim复制认证头后未擦除、append隐藏失败副本 | bounded节点借用保护header，不再复制字符串 | 04无网络C故障矩阵、auth→TransportOwner→C公共链 |
| 业务进程/独立runner仍读秘密env、重建丢owner | 受限Demo frame直接填保护页、角色隔离、父子owner生命周期 | 05实施中，尚未最终关闭 |
| 迁移EnvFile不能丢账户前后验门 | 原生GET guard保留UID/模式/权限/挂单/负债/敞口合同 | 08完整guard已完成，Windows Debug/ReleaseSafe与WSL Linux各10/10；05实际接入待最终验证 |
| 所有修复属于同一最终源码 | 独立双轴审查、冻结source/producer/dependency、全量及入口验收 | 06待05完成后执行 |

## 原始失败与证据边界

- 原始KDF释放后KEK恢复只在ReleaseFast复现；ReleaseSafe原allocator的0xaa覆盖不是安全擦除，也不能声称该模式已重现相同泄漏。HMAC pad残留则两模式均有原始合成复现。
- 中断的损坏checkout及其索引先保全再恢复；见recovery.md。03测试最初错误fixture、WSL1 statx observer失败，04 C误触stub假绿，07辅助排序元数据v1均保留并明确分类，不能计作产品红或最终资格。
- Windows、WSL功能路径分别列证据。Linux低memlock必须拒绝；WSL1可能忽略内核mlock限额，因此模块自己的计费检查不被测试bypass替代。
- 无真实凭证、网络、交易或部署。编译器寄存器/隐式临时、TLS/OS内部、异常强制终止后的清理、目标机dump/swap/掉电与生产准入不由本轮离线测试证明。
