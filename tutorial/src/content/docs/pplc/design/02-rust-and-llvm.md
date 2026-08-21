---
title: 2. 为什么选择 Rust 与 LLVM
description: 前端实现语言、后端基础设施和项目边界的取舍。
---

pplang 追求系统编程能力，但 pplc 没有一开始就自举，而是选择 Rust 写前端、Inkwell 连接 LLVM 18。这让项目把精力集中在语言语义，而不是先实现寄存器分配器、目标指令编码和链接器。

## Rust 对编译器前端的适配

AST 是一组“若干情况之一”的数据。Rust 的代数数据类型能直接表达它：

```rust
pub enum Expr {
    Int(i64),
    Bool(bool),
    Var(String),
    Binary { op: BinOp, lhs: Box<Expr>, rhs: Box<Expr> },
    Call { callee: String, type_args: Vec<Type>, args: Vec<Expr> },
    // ...
}
```

`enum + match` 让新增 AST 节点时的遗漏变成编译错误；`Box<Expr>` 明确递归结构的间接层；`Result<T, String>` 让错误沿流水线传播；`HashMap` 和 `HashSet` 很自然地承载符号表、实例缓存与访问集合。

所有权同样有实际价值。单态化需要克隆模板并替换其中的类型，Rust 会迫使实现明确“是在共享、借用还是生成一棵新树”。代价是 AST 改写和 LLVM context 生命周期会带来额外类型复杂度，这不是免费的安全。

## 为什么不手写机器码

LLVM IR 位于语言语义与机器指令之间。pplc 负责决定：

- `str` 是 `{ptr, len}`；
- `enum` 的 tag 和 payload 怎样布局；
- `u32 / u32` 应是无符号除法；
- `if`、`while`、`defer` 形成什么控制流；
- C ABI 边界如何传值。

LLVM 负责把这些已明确的决定变成特定 CPU 的指令，处理合法化、寄存器分配、指令选择和目标文件编码。这样的边界很重要：LLVM 不知道 pplang 规范，也不会替前端修复错误语义。

## 为什么通过 Inkwell

Inkwell 给 LLVM C API 提供带 Rust 类型和生命周期的封装。`Context` 拥有 LLVM 类型和值，`Module` 拥有函数和全局对象，`Builder` 在 basic block 中插入指令。它比拼接文本 IR 更不容易产生拼写和引用错误，也更适合逐步构造控制流。

但封装不等于验证。Builder 能构造出的 module 仍可能违反控制流、类型或 ABI 约束，因此编译器仍应运行 LLVM verifier，并为关键 lowering 写测试。当前 v0.3 已把 module triple 设为宿主目标，但优化级别仍是 `None`，也没有显式 pass pipeline。

## 没有选择什么

- 没有用 parser generator：v0.3 文法规模适合手写递归下降，语法与诊断路径更直观；
- 没有先自举：让语言成熟度被编译器成熟度锁死，会增加早期迭代成本；
- 没有手写后端：ppos 需要裸机目标，但项目目标不是重新实现 x86 指令选择；
- 没有引入大型编译框架：pplc 六个核心模块约数千行，透明度比扩展性更重要。

未来若要做跨模块优化、借用分析或复杂诊断，可以增加带 source span 的 HIR/MIR；在 v0.3，直接路线更符合教学目标。
