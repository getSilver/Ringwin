## Agent skills

### Local issue tracker

创建、读取、更新或执行 issue/spec 时，使用 `.scratch/<module>/map.md` 与其 `issues/` 目录；除非用户明确要求，不同步到 GitHub Issues。详见 `docs/agents/issue-tracker.md`。

### Domain docs

设计领域模型、修改核心模块或编写 issue/spec 前，读取根级 `GLOSSARY.md` 和相关 `docs/adr/`；本仓库采用 single-context 布局。详见 `docs/agents/domain.md`。

## 文件与目录归属

新增或移动文件前，先按职责选择现有目录，并检查同类文件的组织方式。

### 源码目录

- `src/model/`：Venue 中立的规范领域事件与共享数据合同。
- `src/trading/`：TradingShard、权威配置、控制事实和状态演进。
- `src/execution/`、`risk/`、`portfolio/`、`market/`：执行、风控、经济账户与公共行情。
- `src/adapters/<venue>/`：交易所协议、认证、编解码与 transport。
- `src/persistence/`：日志、快照、持久化与恢复存储。
- `src/strategy/`：策略定义、注册、Host、加载与生命周期。
- `src/runtime/`：运行组装、控制通道、只读控制投影、切换、恢复和遥测。
- `src/security/`：凭证、密码学与秘密内存。
- `src/testing/`：共享 fixture、契约、独立回归、集成和验收程序。
- `src/benchmarks/`：性能测量入口。

### 放置规则

- `src/` 根目录仅放正式可执行入口和统一分发入口；入口保持轻薄，
  具体实现放到所属职责目录。
- 文件内单元测试与实现共置；独立夹具节点、验收探针和回归程序放入
  `src/testing/` 对应子目录。
- Python 源码放在 `python/`，仓库构建与维护脚本放在 `tools/`。
- 临时调试代码和构建产物放在被忽略的 `.scratch/build/` 下；
  需要长期保留的检查转为所属模块的正式测试。
- 优先复用现有目录；新增目录必须有独立职责，避免按任务编号或临时用途组织源码。
- 独立 Zig 验收程序复用 `src/entry.zig` 和 `tools/zig-entry.py`，
  保持 `src/` 为模块根目录，不因编译方便将实现移回根目录。
- 移动文件时同步更新 import、构建入口、调用脚本及当前文档；
  历史验收报告中的原路径和身份保留原样。
