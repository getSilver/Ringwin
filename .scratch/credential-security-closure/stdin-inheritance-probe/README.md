# Windows 原始 stdin 继承探针

此探针只验证外层脚本能否把受限输入的原始字节交给最终 native 子进程，不启动 RingWin，不使用凭证或网络。773字节固定合成内容包含NUL、CR/LF及高位字节；子进程只输出长度和SHA256。

实际执行源位于 `D:/github/Ringwin-credential-recovery-20261018/stdin-inheritance-probe/`，本目录逐字节复制并核验。`result.json`记录PS7 ProcessStartInfo；`ps51-results.json`记录Windows PowerShell5.1的ProcessStartInfo与直接native调用。三种均exit0、长度/摘要一致。PS5.1使用Arguments，不能使用PS7/.NET的新ArgumentList接口。

这不是受保护凭证parser或应用验收结果。05仍需用实际包装脚本/合成child证明其合同；构建进程须使用独立空stdin，只有最终native消费者继承输入，不应通过PowerShell字符串或pipeline文本重建frame。公开的非秘密argv仍须正确引用。
