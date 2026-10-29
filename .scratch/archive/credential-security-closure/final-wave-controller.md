# 最终冻结验收的持久控制器

`final-wave.py` 接受预先冻结的 JSON plan；每步前后校验完整源码身份与 producer 文件哈希，串行调用已有 `capture.py`。首个非零结果立即停止，不自动重试、不覆盖旧 label。`runs/<wave>/state.json` 原子记录控制器 PID、当前步骤和已完成结果，方便界面中断后检查。

最终 plan 只能在代码审查、修复及定向回归完成后生成；本文件和 selfcheck 不表示最终冻结或应用验证完成。正式启动使用 `Start-Process -WindowStyle Hidden`，指定独立 stdout/stderr 文件并记录 PID；不要通过界面工具的短命会话持有长测试。不能同时启动第二份全量测试。

`controller-selfcheck-plan.json` / `runs/controller-selfcheck-v1*` 是纯合成控制器自检：第一步 exit0、第二步故意 exit7，控制器保存 failed 并未执行第三步。控制器 exit1 是预期结果，不是应用回归失败；没有启动 RingWin 或网络。Python 语法检查通过。四个 capture 自检仍保留自己的生产脚本身份，不提升为新版应用或目标机资格。
