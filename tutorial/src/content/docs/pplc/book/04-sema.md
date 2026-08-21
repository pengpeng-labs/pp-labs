---
title: 4. 语义分析：环境、类型与作用域
description: 把上下文相关规则写成可执行的类型判断。
---

parser 能确认 `if (x) { ... }` 形状合法，却不知道 `x` 是否存在、是否为 `bool`。这些依赖声明环境的规则属于 semantic analysis。

TAPL 常把类型判断写成：

```text
Γ ⊢ e : T
```

读作“在类型环境 Γ 中，表达式 e 具有类型 T”。pplc 的变量表、函数表、struct/enum 定义就是 Γ 的工程表示，`expr_type` 一类函数就是判断过程。

一个类型系统不是“给每个 AST 写 if”而已。它由 judgments 和 inference rules 组成；实现 sema，就是把这些规则变成一个可终止、能产生诊断的算法。

## 从判断规则到 Rust 分支

变量规则是：

```text
x : T in Γ
────────── T-Var
Γ ⊢ x : T
```

对应 `Expr::Var(name)`：从最内层 scope 开始查 `name`，成功返回绑定类型，失败产生 unknown variable。整数和 bool literal 则无需环境：

```text
──────────── T-Int          ────────────── T-Bool
Γ ⊢ n : int                 Γ ⊢ b : bool
```

函数调用规则可以简化为：

```text
Γ(f) = (T1, ..., Tn) -> R
Γ ⊢ a1 : T1  ...  Γ ⊢ an : Tn
────────────────────────────── T-Call
Γ ⊢ f(a1, ..., an) : R
```

工程实现还要检查 arity、允许的 coercion、extern/varargs 和显式类型实参。规则上没有写出的条件不能凭空消失，而应作为 side condition 明确实现。

## 条件为何只能是 bool

对 `if` 的规则可以简化为：

```text
Γ ⊢ condition : bool
Γ ⊢ then-branch ok
Γ ⊢ else-branch ok
─────────────────────────
Γ ⊢ if ... ok
```

因此 `if (1)` 必须在 sema 被拒绝。LLVM integer `i1`、`i8`、`i32` 都是整数类型，但这不意味着 pplang 应允许任意整数充当真假值。源语言规则必须先于 LLVM 的表示便利。

可以为 `if (1)` 构造失败推导：T-Int 能得到 `Γ ⊢ 1 : int`，但 T-If 的第一前提要求 `bool`，没有规则能把 `int` 隐式变成 `bool`，所以推导停住。编译错误正是“无法构造合法 derivation”的算法化表现。

## 词法作用域是一组栈帧

进入 block 时 push 一个 scope，离开时 pop。查找名称从最内层向外层进行：

```pp
let x: int = 1;
if (true) {
    let x: int = 2;
    print(x); // inner x
}
print(x);     // outer x
```

shadowing 不等于覆盖外层 binding。若只用一个 `HashMap<String, Type>`，内层插入会销毁旧值，离开 block 后无法恢复；scope stack 才直接对应词法作用域的嵌套结构。

codegen 也需要同样的作用域，因为名称最终映射到 LLVM alloca/address。静态检查和 lowering 两处必须遵守同一个 push/pop 边界。

block 的环境规则可以写成：

```text
Γ0 = Γ
Γ(i+1) = extend(Γi, binding introduced by si)
Γi ⊢ si ok  for every statement si
──────────────────────────────────── T-Block
Γ ⊢ { s1; ...; sn } ok
```

block 结束后丢弃最后的扩展环境，回到 Γ。这正是 scope stack 的 push/pop。shadowing 是在新 Γi 顶层增加同名 binding，不是修改外层 Γ。

## 类型相等与允许的转换

语义分析不能用“LLVM 最后能 cast”作为接受依据。pplang v0.3 区分：

- 完全相同类型；
- 规范允许的数值转换；
- 显式 `as` cast；
- 指针与 `str` 的 ABI 边界；
- 完全禁止的转换，如隐式 `int -> bool`。

对 assignment、return、call argument 应复用同一套兼容规则，否则会出现“能赋值但不能传参”的语义裂缝。

最好把它写成单独 judgment `S => T`，表示源类型 S 可在上下文中隐式转换为 T。assignment、return 和 argument rule 都引用这一个 judgment。显式 cast 则是另一组更宽但仍有限的规则。这样规范、sema 和 codegen 的 `coerce` 才有一份可对照的合同。

## lvalue 与 addressability

不是所有表达式都能出现在赋值左侧或取地址。变量、字段、索引和解引用通常是 lvalue；整数常量和加法结果不是。指针 receiver 自动取址也依赖 addressability：局部 struct 变量可以自动变成 `*T`，临时计算值则不能凭空获得稳定地址。

这说明表达式分析不只回答类型，还可能回答 value category。pplc 当前通过专门的 lvalue 路径处理；更丰富的中间层通常会显式记录这一属性。

## 错误优先级

一个表达式可能同时有多个问题。实用策略是从局部到整体：先报告未定义名称和类型不匹配，再检查 enclosing return 或穷尽性。错误信息要包含“期望什么、实际是什么、处于什么语境”，而不是把后端的 `expected integer value` 泄漏给用户。

## 回归测试

`pplc/tests/compiler.rs` 同时覆盖：条件拒绝整数、block shadowing 恢复外层 binding、block-local 离开后不可见。它们是同一个环境模型的三面。修改 scope 代码时，三者应作为一组运行，而不是只看 happy path。

## 类型安全在这里意味着什么

TAPL 用 progress 和 preservation 描述 soundness：良类型程序要么已经是值，要么还能继续求值；每一步求值后类型仍被保存。pplc 没有机械证明，但能把它转成工程问题：

- progress 压力：bool condition、穷尽 switch、合法 call target、有效 lvalue；
- preservation 压力：赋值、return、cast、payload 解包后仍保持声明类型；
- 不在保证内：raw pointer、FFI、volatile 和内存生命周期可能破坏更强的 memory safety。

所以“通过 sema”不是“程序绝对安全”，而是“满足 v0.3 静态语义所承诺的类型安全范围”。
