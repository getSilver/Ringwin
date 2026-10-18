# 04 认证与传输副本修复

2026-10-18。原实现提交 `f426b3c8` 与中断后的未提交修改均保留；接续在原工作树完成，没有替换或删除原实现。README 重复的 KDF 说明只保留一份；C 源换行恢复已提交格式后确认没有遗漏实质修改。

## 实现与接口

- Credentials 独占 native protected Buffer，输入长度先验证，再复制到已取得锁页/dump保护的目的地，sealLengths 冻结只读，失败和 deinit 擦除整个映射。init 输入只在调用期间借用，调用方仍须清理原输入；05 应优先直接填充 initEmpty → writableFields → sealLengths 的保护目的地。
- TransportOwner.init/initWithEndpoint 借用 `*const Credentials`，不接管或复制 SecretMaterial。owner 重建/错误清理不释放借用映射；凭证所有者必须存活至全部 transport owner deinit 后。05 接续更新网关及独立运行入口。
- RFC2104 HMAC 的 key、ipad/opad、SHA256 context、schedule/compression words、digest 均在受保护 Scratch 内，成功/失败安全擦除；SHA256 为固定 Zig commit 5b647b792 的窄适配，保留 MIT 来源。RFC4231、独立长 key 和原 OKX 签名向量保持一致。
- Headers、LoginPayload 和 signature scratch 由保护映射拥有，构造失败 errdefer 擦除，正常消费后 clear。api-key/passphrase/timestamp 拒绝 NUL、CR、LF；JSON 容量失败也覆盖释放前清零。
- C shim 取消 curl_slist_append 的认证字符串复制，改用有界 stack 链表节点借用保护 header bytes。节点只有指针，保持至同步调用 curl_easy_cleanup 完成；shim 没有自己拥有的 secret 文本副本。C 测试替换所有 easy 请求操作，覆盖 init、每个 setopt、send/recv 失败、成功、header 数量/空指针拒绝及 cleanup 借用生命周期，无网络路径。

## 证据与中断恢复

原 v2 auth 三模式与 Linux 各10/10；transport v2 为1/1，C final 为合成成功。原轮缺少完整 producer 命令/退出码/源身份，不能从多个 cache 同名产物反推绑定。本次使用04-recovery-validate.py和capture.py最小定向补证，串行记录命令、退出码、前后源码、编译器、CURL依赖、产物及日志 SHA；不重跑 main 全量。Windows Debug/ReleaseSafe/ReleaseFast auth各10/10、Linux ReleaseSafe auth10/10、合成transport1/1和C编译/运行全部退出0，共8阶段。结果见04-recovery-validation.json及runs/04-recovery-v1-*。合入03集成32ab7200后验证auth/C生产输入SHA不变，不重跑auth；C合成测试只规范LF，另补3个transport/C小阶段均退出0，见04-postmerge-validation.json。汇总及全部历史原件分类见04-validation.json。

历史原件保留并分列：04-auth-red.log是新接口不存在的编译红；04-injection-red.log是头注入被接受的行为红；04-c-red-checked.log是实际 shim 借用检查的行为红。04-c-red.log误用stub旧代码而假绿，属于无效诊断，不能视作red或资格；04-transport-safe.log是初始enum类型推断编译错误，后续类型明确的版本通过。各阶段日志不改写覆盖。

## 验收边界

根应用及 windows_verification_runtime、okx_demo_live_acceptance、okx_curl_private_smoke 的旧 by-value/env 凭证入口由票05继续修改；本票不声称这些根入口当前可编译或已安全注入。生产 admitExecution 保持 out-of-scope。编译器寄存器/隐式临时值、libcurl/TLS/OS 内部缓冲、真实凭证、目标 dump/swap 和目标机平台资格未取得。本轮没有网络、部署或交易。
