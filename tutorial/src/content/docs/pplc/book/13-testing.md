---
title: 13. 测试编译器，而不只测试样例
description: 正例、反例、IR 断言、golden、差分与端到端验证。
---

编译器的输入空间巨大，一个 hello world 成功不能说明语言实现正确。测试设计应对应每个阶段的不变量。

## 从规则系统生成测试

前面每条 inference rule 都天然给出正例和反例。以 T-If 为例：

```text
Gamma ⊢ c : bool
──────────────── T-If
Gamma ⊢ if c ... ok
```

正例让 premise 成立：`c=true`。反例逐个破坏 premise：`c=1`、`c=ptr`、`c=void-call`。这种方法比凭经验罗列程序系统得多，也能明确错误应在 sema 而不是 LLVM codegen 出现。

对 parser production 同样适用：为每个 alternative 准备最小成功输入，为每个 delimiter 准备缺失/错位输入；对 sum type 的 F/I/E 规则分别测试类型形成、构造和消去。

## 四类测试

| 类型 | 观察 | 适合发现 |
|---|---|---|
| 正例运行 | 退出值与输出 | 端到端行为回归 |
| 反例编译 | 非零状态与诊断 | parser/sema 接受了非法程序 |
| IR 结构 | 指令、predicate、signature | lowering 选错语义 |
| 构建/链接 | object/executable/freestanding | target 与 ABI 集成问题 |

`pplc/tests/compiler.rs` 的 helper 把源码写到临时 `.pp`，调用构建出的 `pp`，再检查 stdout/stderr/status。测试以用户真正使用的 CLI 为边界，因此能覆盖模块连接问题。

还可以按编译阶段划分 oracle：

| 阶段 | Oracle |
|---|---|
| lexer | 精确 token kind/value/span |
| parser | 结构化 AST，而非 Debug 字符串 |
| sema | accept/reject + 稳定错误类别 |
| mono | concrete instance set + 无自由 type params |
| LLVM | verifier + 关键 IR property |
| execution | stdout、return、trap、外部副作用 |

越靠前的失败越应使用越局部的 oracle。用最终退出码定位 lexer 的一个列号 bug，反馈太间接。

## 一个语义承诺需要多面证据

“u32 使用无符号除法”至少应有：

1. IR 包含 `udiv i32`；
2. 用最高位为 1 的 operand 运行，结果符合 unsigned；
3. `int` 对应路径仍是 `sdiv`；
4. 混合宽度/类型遵守规范的 promotion。

“switch 穷尽”则需要完整成功、漏 variant 失败、重复 variant 失败、wildcard 成功和 wildcard 顺序失败。

这对应两类正确性：type checker soundness 要求被接受程序满足规则，completeness 要求符合规则的程序不要被误拒绝。工程测试无法证明两者对无限输入成立，但正反例矩阵能持续暴露规则实现的偏差。

## 诊断也属于接口

反例不能只断言“失败了”。至少检查诊断包含稳定的错误类别与关键名称，例如 `condition must be bool` 或缺失 variant。不要把完整 Rust Debug AST 当 golden，它会让内部重构无谓破坏用户接口。

未来引入 source span 后，可为小型错误做 snapshot/golden：文件名、行列、source excerpt、期望/实际类型。golden 应少而精，语义条件仍用结构化断言。

## 分层测试

黑盒 CLI 测试很重要，但 lexer/parser 的密集边界适合模块单元测试：输入 token 序列或 AST，错误定位更快。建议测试金字塔是：

- 大量 lexer/parser/sema unit cases；
- 中等数量 CLI compile-fail/run cases；
- 少量真实 ppdb/ppos build 与运行验收。

真实项目是不可替代的 workload。ppdb 会压力测试大量 struct、容器、字符串和持久化 FFI；ppos 会压力测试 static、volatile、ABI 和 freestanding。但项目能构建也不能替代语言反例测试，因为它只覆盖自己恰好使用的路径。

Database System Concepts 在这里提供的不是 compiler algorithm，而是 workload semantics：索引更新、事务回滚和持久化让错误的 integer width、aliasing、string length 或 FFI ABI 变得可观察。网络与 OS 项目以同样方式提供 byte order、volatile、freestanding 和异步控制流压力。

## 属性和差分测试的下一步

lexer 可生成随机 token 间空白/注释，验证 AST 不变；整数运算可将 pp 结果与 Rust/C oracle 对比；parser 可做 AST pretty-print round trip（若以后加入 formatter）。这些方法来自测试理论，不要求先有大规模优化器。

另一个重要概念是 translation validation：与其证明整个 code generator 永远正确，不如对每次产物执行可计算检查。LLVM verifier 是结构层 validation；module triple/data layout consistency、实例闭包和“每个 block 有 terminator”也可以成为 phase postcondition。它们不替代语义测试，但能把错误拦在最近阶段。

优化出现后还可做 differential testing：同一 pp 程序分别用 O0/O2、JIT/object 路径执行，比较可观察行为。若不同，至少一个 pipeline 破坏了 preservation。

## 每次新增语言特性的完成定义

1. spec 给出接受与拒绝规则；
2. AST 能无歧义表达；
3. sema 有明确错误；
4. codegen 生成目标无关的正确 IR；
5. 正例、反例、边界值和 IR 都有测试；
6. 至少一个真实 workload 使用；
7. 教程与 reference 同步。

编译器的“完成”不是代码路径存在，而是这七层承诺互相对齐。

## 实验：由一条规则扩展完整测试

选择 unsigned comparison 规则，写出 operand typing、usual promotion 和 result bool 的 judgment。然后生成：同宽正例、跨宽度正例、signed/unsigned 边界、非法 operand 反例、IR predicate 断言和最大位模式运行结果。最后标出每个 case 证明规则的哪个 premise 或结论。
