# PS5.1 构建空 stdin 的 BOM 根因

纯合成实验，不启动 RingWin、不读凭证文件、不连接网络。实际源位于外部恢复目录 `D:/github/Ringwin-credential-recovery-20261018/empty-stdin-probe/`，本目录按原字节复制并校验。

`probe.ps1`/`result.json` 显示：PS5.1 默认输入编码下，ProcessStartInfo.RedirectStandardInput=true 的子进程读到3字节EFBBBF；Close与BaseStream.Close都如此。BOM在Process.Start创建writer时已经写出，不能把这3字节误称为秘密frame泄漏。PS5.1也没有StandardInputEncoding属性。

在Start前临时将Console.InputEncoding设为UTF8Encoding(false)，关闭重定向流并在finally恢复原编码，子进程实际读到0字节。`probe-forward.ps1`/`forward-result.json`进一步证明：恢复后最终native继承的773字节输入长度及SHA仍与原合成字节一致。ASCII模式也可为空，但实际方案选无BOM UTF8；所有变动仅在本进程临时生效。

这只是进程边界实验；05须在实际四个launcher的合成镜像验证后才能授予包装层功能证据，不能代替应用/平台资格。
