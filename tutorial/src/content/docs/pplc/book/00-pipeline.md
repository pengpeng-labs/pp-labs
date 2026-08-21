---
title: 0. 先跑通一条编译流水线
description: 用最小程序观察 source、AST、LLVM IR 与机器交付的边界。
---

先不钻进任何模块。我们用一个函数建立整条流水线的坐标：

```pp
fn twice(x: int) -> int {
    return x * 2;
}

fn main() -> int {
    return twice(21);
}
```

将它保存为 `/tmp/twice.pp`，在 `pplc` 目录运行：

```bash
cargo build
./target/debug/pp run /tmp/twice.pp
./target/debug/pp ir /tmp/twice.pp
./target/debug/pp obj /tmp/twice.pp -o /tmp/twice.o
```

`run` 最后打印 `42`。`ir` 会出现 `define i32 @twice(i32 ...)`、`mul i32` 和对 `@twice` 的 `call`。变量名、临时值编号等细节可能变化，语义骨架不应变化。

## 五种程序表示

同一个程序在 pplc 中至少有五种形态：

1. 源码：面向人和 LLM 的具体语法；
2. token：去掉空白与注释后的词法单位；
3. AST：`Function`、`Return`、`Call`、`Binary` 组成的树；
4. LLVM IR：带基本块、类型和指令的数据流图；
5. 目标文件：机器码、符号、重定位与 section 的容器。

PLAI 提醒我们不要把这些表示当成无关的数据格式。每一种表示都在回答“程序是什么”：具体语法回答人怎样写，AST 回答语言有哪些构造，LLVM IR 回答控制与数据怎样流动，目标文件回答机器和链接器怎样接收它。

可以把整条流水线写成一组翻译函数：

```text
parse : Source -> AST
mono  : GenericAST -> ConcreteAST
check : ConcreteAST -> Result<TypedProgram, Error>
lower : TypedProgram -> LLVMModule
emit  : LLVMModule -> Object
```

当前 pplc 没有单独的 `TypedProgram` 数据结构，`check` 成功后仍把原 AST 交给 codegen。这是实现上的合并；概念上，codegen 的前置条件已经改变：它只应收到通过 v0.3 语义检查的程序。

## 保语义翻译

如果用 `eval_source(p)` 表示 pp 规范赋予程序 `p` 的行为，用 `run_object(compile(p))` 表示编译结果的行为，编译器希望维持：

```text
eval_source(p) = run_object(compile(p))
```

本课程不会形式化证明整个 pplc，但每个阶段都能维护一个较小的对应关系：

| 翻译 | 应保留什么 | 典型反例 |
|---|---|---|
| source -> AST | 结合性、求值次序、binding 结构 | `a-b-c` 被解析成 `a-(b-c)` |
| generic -> concrete | 类型替换后函数体含义 | 漏替换 `*T` 内部的 T |
| AST -> IR | 数值、内存和控制效果 | `u32 / u32` 生成 `sdiv` |
| IR -> object | ABI 与目标布局 | module 与 TargetMachine data layout 不同 |

这就是“阶段不变量”比“调用顺序”更重要的原因。测试也应围绕这些可破坏的关系设计。

源码中的 `return x * 2` 在 AST 中接近：

```text
Return(
  Binary(Mul,
    Var("x"),
    Int(2)))
```

在未优化 IR 中，参数通常先写入 entry block 的栈槽，再 load、mul、ret。这个内存式 lowering 很直观，但不是 SSA 的最终美观形态。LLVM 的 `mem2reg` 一类 pass 可以把适合提升的栈槽变成 SSA 值；pplc v0.3 默认 `OptimizationLevel::None`，因此教程不会假设优化已经发生。

## 前端与后端在哪里分界

“前端”不是 lexer + parser 的同义词。对 pplc 来说，前端结束时应已经回答：

- 每个名称指向什么；
- 每个表达式的类型是什么；
- 泛型使用对应哪个具体实例；
- `switch` 是否穷尽；
- 作用域与控制流是否合法。

后端接收这些决定，把它们编码成 LLVM 类型、值、基本块和调用约定。若后端还在猜一个表达式是 `int` 还是 `u64`，阶段契约就不够强。

龙书通常把 lexical、syntax、semantic analysis 归入前端，把 IR optimization 与 target code generation 放在后端。pplc 借 LLVM 承担大部分 target-dependent backend，自己写的 `codegen.rs` 更准确地说是“source language 到 LLVM IR 的 lowering”。它既理解 pp 类型，又开始服从机器 ABI，位于传统前后端的接缝处。

## 第一个实验

把 `twice` 的参数和返回类型改成 `u32`，再查看 IR。乘法本身没有 signed/unsigned 版本；把运算改成除法后，则必须看到 `udiv` 而不是 `sdiv`。这说明“同样宽度的 LLVM integer type”并不保存源语言的有符号性，前端必须携带这部分语义直到选择指令。

后续每一章都沿用这种观察方法：选一个很小的源程序，确定阶段不变量，再检查错误或 IR 中能直接观察的证据。
