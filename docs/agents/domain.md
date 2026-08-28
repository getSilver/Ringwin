# 领域文档

本仓库采用 single-context 布局。

## 工作前读取

- 读取根级 `CONTEXT.md`，使用其中定义的规范领域语言。
- 读取 `docs/adr/` 中与本次工作相关的架构决策。
- 如果上述文件不存在，继续工作；只在术语或难逆决策实际形成时通过 domain modeling 创建。

## 使用规则

- issue 标题、spec、重构方案、测试名称和代码术语使用 `CONTEXT.md` 的规范词汇。
- glossary 明确列入 `_Avoid_` 的同义词不作为新术语使用。
- 需要的概念尚未定义时，先判断它是否是真实领域缺口；确认后通过 domain modeling 补入
  `CONTEXT.md`。
- 输出与已有 ADR 冲突时，明确指出冲突和重开该决策的理由，不能静默覆盖。

## 布局

```text
/
├── CONTEXT.md
└── docs/
    └── adr/
        └── 0001-*.md
```

如果仓库未来演化为真正的多 context 结构，再增加根级 `CONTEXT-MAP.md` 并把各 context 的
`CONTEXT.md` 与 ADR 放到对应目录；当前不预建该结构。
