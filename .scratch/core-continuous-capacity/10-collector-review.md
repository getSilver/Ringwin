# 10 collector 独立复核

审查者：`safety_backpressure`，只读复核，未运行collector或修改其源码。最终SHA256 `da8ebdf768011ade28a510c74b7d1c20dde46a785442fd3c898d1b969831b21c`。

原P2是仅扫描根级result，漏掉实际64MiB应用栈溢出`10-dev-small-v1/seed.result.json`。已改为限定Frontier10根级及10-*子目录内递归扫描，保留相对路径，并将主动终止与开发失败分别标注。独立selector实际检查37份结果、16份非零结果，确认包含exit3的原始失败；P2关闭，无剩余确认P1/P2。

collector只在最终audit为passed后汇集真实输入，自身SHA与所有读取文件SHA进入独立identity；没有干预运行中的六份冻结producer或Zig源码。此审查不替代完整套件、最终十轮、audit和实际封存退出码。
