# Frontier 12 Standards review

审查基点：`f8b6a88e0add894bef910eb577d210ff96e0ca90`；对照该基点至当前提交及票12新增覆盖、交接、证据与复核文件。共同源码115文件，SHA256 `244f3ae77d0978357809cbf99bf850ba89282799a5902323727d54d62c91233d`。

**0 项未解决 P1/P2。**

按 `AGENTS.md`、`GLOSSARY.md`、`docs/agents/domain.md`、`docs/agents/issue-tracker.md`、ADR0004和0010审查；仓库未另设 CODING_STANDARDS/CONTRIBUTING。未发现需要报告的 baseline smell，工具可检查项不作人工finding。

- 票12不修改Zig业务源码。Windows重建显式绑定共同源码、编译器、六个producer、构建参数、PE栈预留与消费SHA；应用64MiB、CLI/测试256MiB均未误报实际栈峰值或生产预算。
- `audit-12-final.py`拒绝失败、超时、fatal及源码/producer漂移，校验原始stderr/stdout/memory摘要、归档逐文件内容和产物身份。v2审计记录16阶段退出0、333项受影响Debug通过、两产物各30个真实进程及5个实际数据目录；18条故障/拒绝记录保持其hook或物理变更范围。
- 物理目录比较路径、长度和内容SHA，资源allocation仍保留观察值；完整恢复权威、递增历史身份与零重发由共享验证入口负责，未引入平行业务解释器。
- 历史Windows完整套件继续属于票10旧源码；当前Windows受影响回归和Linux当前源码完整套件未互相替代。WSL1与Windows目录flush限制、千单/压力/预算及独立生产资格均明确未测或未合格。
- v1中断保留98项引用并经覆盖文档固定SHA传递绑定；`verify-12-seal.py`补核包manifest、全部封存引用及98项子引用，保持复核职责独立，不改运行期producer。

最终独立运行 `verify-12-seal.py 12-final-v2`：7个manifest文件、3334项封存引用和v1的98项子引用全部字节SHA匹配。包manifest SHA256为 `64672c5d303eaa12b20966902d5e1ad59104228f07759264bb78720ba885746b`。另直接复核6个producer、16份capture及其48份原始日志/采样摘要、333项测试日志和6个PE身份均通过。封存后覆盖/交接字节保持固定；0项Standards阻塞，仅支持本轮小规模功能闭合。
