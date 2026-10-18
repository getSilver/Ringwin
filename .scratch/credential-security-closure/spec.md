# 凭证安全修复规格

基线：`c5f73ba08ed10e6a5f42e97264f4c72e9b2f2864`，固定 Zig `0.17.0-dev.315+5b647b792`。
来源：当前审计、`docs/加密任务.md`、CONTEXT 的 SecretMaterial/ProtectedSecretMemory/SecurityAdmission、ADR0005/0010。

## 授权与公共测试seam

用户明确授权实现、验证、提交；2026-10-18已确认以下seam，不需逐用例再问：

1. CredentialStore 公开stage/状态切换/准入，真实pipe/TTY及文件重开；观测生命周期、输入完整性、保护失败和清理，不替代目标设备掉电。
2. 受保护内存分配/访问/释放接口；通过受控backend/分配器观测锁页顺序、失败清理、显式擦除以及真实OS能力，不把测试bypass当成native。
3. OKX auth→TransportOwner→C shim 的合成请求/受控进程启动；观测签名一致、请求副本和凭证注入，禁止实际网络或真实密钥。

## 行为合同

### 生命周期

- stage只允许该kind的首次登记。已有staged/active/retiring/revoked或损坏文件均不覆盖；重试不能重设ID/version/generation，错误保留原字节。
- 生命周期持久化更新校验当前认证metadata与generation；并发更新不能把revoked覆盖成旧active。独立writer锁/原子exclusive首次发布和唯一临时文件，所有失败关闭并关闭句柄/清理自有临时文件。
- 不隐式升级旧容器格式；新版本完整轮换仍需独立明确入口/合同，不把首次stage作为轮换。

### 内存和密码学

- 提供集中拥有的页对齐保护内存，先锁页/取得所需dump保护再写敏感内容；存活只读可按需切换。释放先恢复写权限、secureZero、解锁，再释放；锁定/保护失败不产生可用lease。
- Linux native必须锁页并DONTDUMP；Windows只在既有verification合同报告能力，不声称Windows目标dump资格。测试bypass仅编译期测试可用，不能配置成生产绕过。
- store内部的口令、KEK、plaintext、decode结果和encode工作区避免普通长期副本与按值复制；公有stage兼容输入的调用方原缓冲必须在成功和失败均擦除，新的gateway输入直接进入保护存储。
- KDF仍为同参数Argon2id/XChaCha20-Poly1305，原文件可读。必须清理19MiB工作区和应用可管理的h0/crypto状态，不以ReleaseSafe的0xaa为安全保证；必要时使用固定版本、保留许可证/来源的窄密码学实现适配，禁止自创算法。
- HMAC/签名中间状态、signature/digest及认证请求缓冲显式擦除；已知签名向量保持不变。明确区分应用可控内存、编译器临时值和TLS/OS内部内存，不能声称已证明擦除了后两者。

### 输入与业务接入

- 原生Linux必须安全关闭TTY回显并恢复；若无法保证信号/异常恢复，明确拒绝TTY而只支持受限pipe/socket，拒绝发生在读取口令前，不保留一个仍回显的兼容入口。Windows保留已有关闭echo行为并覆盖错误清理。
- 超长/无终止完整性异常输入明确拒绝，不静默截断为前缀密码；拒绝普通文件/argv/env密码来源。失败擦除目标缓冲。
- 原始密钥不得再经业务子进程环境传递。网关使用受限输入/加密store，owner生命周期持有保护存储；分离observation与execution，以及demo/testnet/production。
- 不打开生产execution admission。现有Demo工具使用新的受控注入入口；旧秘密环境变量入口明确拒绝或删除，不静默回退。脚本只在另外明确授权的线上运行时才会实际调用，本轮只静态/合成检查。
- 迁移旧EnvFile preflight必须保留既有账户身份、权限、模式、可用instrument/leverage、挂单/仓位/负债/资金敞口和时钟安全门；08原生只读guard供05在首次写前、正常与失败后复用。不得通过删后验、信任caller UID或永久禁用Windows Demo工具来冒充迁移完成。
- C shim对自己复制的认证头，在正常/分配失败/设置失败/请求失败路径均先安全擦除后释放。TLS库内部缓冲仍是独立目标机/依赖审计范围。

## 验证与资格边界

- 每个任务先单个红测试，再最小修复变绿；保持真实public调用路径，不把private stdlib复现原样当作产品修复通过。
- 日常定向回归串行避免旧固定临时目录碰撞，使用独立cache及自有fixture路径。
- 关闭时记录源码/编译器/模式/命令/产物身份、失败原件及剩余未测。最终冻结后运行一次完整Debug/ReleaseSafe，受影响应用及CLI/独立runner构建，Linux可Windows交叉编译后WSL执行。
- WSL功能通过不替代目标发行版、dump/swap/rlimit/设备耐久性、真实Venue/生产资格；历史容量/线上结果不转授新源码。
