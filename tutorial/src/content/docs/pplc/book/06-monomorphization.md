---
title: 6. 显式泛型与单态化
description: 模板约束、类型替换、worklist、名称改写与递归防护。
---

pplang v0.3 采用 Ada 风格的显式泛型：调用点必须给出类型实参，类型能力必须作为普通函数参数显式传入。

```pp
fn choose[T](a: T, b: T, less: fn(T, T) -> bool) -> T {
    if (less(a, b)) { return a; }
    return b;
}

fn int_less(a: int, b: int) -> bool { return a < b; }

fn main() -> int {
    return choose[int](2, 8, &int_less);
}
```

编译器不会生成一个运行时接受“任意 T”的函数。它发现 `choose[int]` 后，生成只处理 `int` 的具体函数。这就是 monomorphization。

## 类型参数不是运行时值

在 System F 风格的类型抽象中，可以把泛型函数写成类型 lambda，并在类型应用时替换：

```text
identity = Lambda T. fn(x:T) -> T { x }
identity [int]
```

pplang 没有暴露 System F 语法，但显式 `[int]` 保留了 type application 这一动作。单态化执行类型替换：

```text
[int/T](fn(x:T) -> T { x })
  = fn(x:int) -> int { x }
```

类型参数在编译期消失，运行时函数不携带 type descriptor 或 dictionary。好处是具体布局和调用直接；代价是不同实例产生更多代码。

## Parametricity 与 pplang 的约束选择

参数多态中的函数若真的只知道 `T`，它能对 T 做的事情很少：保存、传递、返回，不能凭空相加或比较。这是 parametricity 的工程直觉。

```pp
fn invalid_add[T](a: T, b: T) -> T {
    return a + b;
}
```

`+` 不是对所有 T 都定义。Rust 用 trait bound，C++ 用 concepts/template diagnostics，Ada 使用 formal subprogram/package；pplang v0.3 选择显式函数 capability，例如 `less: fn(T,T)->bool`。模板只调用 `less`，不假设 T 内建可比较，把 constraint 解析降成普通名称解析和函数类型检查。

## 为什么先验证模板

函数体里的 `T` 是未知类型。`a + b` 对某些 T 有意义，对另一些没有。如果只等实例化后检查，模板的有效性取决于恰好有哪些调用点，错误也会远离定义处。

pplang 选择显式能力：模板要比较 T，就接收 `fn(T,T)->bool`；要打印，就接收相应函数。`mono.rs` 的 template validation 在抽象环境中检查：只允许不依赖具体 T 的运算，或通过显式 capability 完成操作。

这不是 Rust trait system 的缩小复制。它用一等函数和显式参数表达约束，语义更少，调用成本和可见性也更直接。

模板环境可以分成两层：

```text
Delta = { T type }
Gamma = { a:T, b:T, less:fn(T,T)->bool }
```

检查 `less(a,b)` 时，T 不需要具体化：从 Gamma 已能证明 argument 类型匹配，call 结果是 bool。检查 `a+b` 时则没有一条“任意 T 支持 Add”的规则，所以模板定义处就应失败。

## 类型替换

实例化 `choose[int]` 时建立 substitution：

```text
{ T -> int }
```

替换必须递归进入所有类型构造：

```text
T                  -> int
*T                 -> *int
fn(T, T) -> bool   -> fn(int, int) -> bool
Option[Pair[T]]    -> Option[Pair[int]]
```

随后函数参数、返回类型、局部显式类型、cast、struct init、enum variant 和嵌套调用中的类型实参都要同步改写。漏掉任何 AST 位置都会产生“表面已具体化、内部仍残留 T”的半实例。

替换必须满足两个基本性质：

- totality：每一种包含 Type 的 AST 节点都有替换分支；
- closure：具体实例输出中不再自由出现模板参数。

Rust 的 exhaustive `match` 能帮助第一项，但只有测试或后置检查能保证第二项。一个实用 invariant 是：进入普通 sema 前，任何可达 concrete item 中都不能残留未绑定 type parameter。

## worklist 而不是单次遍历

一个具体实例的函数体可能调用另一个泛型实例。单态化因此是可达图遍历：

1. 从非泛型函数中的显式泛型使用收集 roots；
2. 将待生成实例放入 worklist；
3. 弹出一个实例，替换模板并扫描它产生的新需求；
4. 对未见过的实例继续入队；
5. 直到 worklist 为空。

`seen`/实例集合负责去重，所以两个调用点使用 `identity[int]` 只生成一份函数。

可以把算法理解为求 reachable instance set 的最小不动点。设 `needs(i)` 返回实例 i 的函数体直接需要的泛型实例：

```text
S0 = roots
S(n+1) = S(n) union union(needs(i) for i in S(n))
```

当 `S(n+1) = S(n)` 时 worklist 为空，算法结束。`seen` 保证有限实例图中的每个节点最多展开一次。这与 import graph 遍历相似，但节点从“文件”变成了“模板名 + 类型实参”。

## 名称改写

LLVM module 中每个函数需要唯一符号。`mangle(name, type_args)` 把模板名和具体类型编码成稳定名称。嵌套类型、指针、数组、tuple 和函数类型都需要无歧义的 type key。

名称改写同时发生在定义和调用点。若只改定义，call 找不到函数；若 key 不稳定，重复实例无法去重。

## 无限实例化

危险模板可能从 `grow[T]` 调用 `grow[*T]`，产生：

```text
grow[int]
grow[*int]
grow[**int]
...
```

普通递归 `fact[int] -> fact[int]` 会被 `seen` 截止，类型不断增长的 polymorphic recursion 则不会。pplc 设置递归/展开防护并拒绝这种程序。这个限制是编译终止性的工程保证。

从不动点角度看，这个程序的 reachable set 是无限集，因此没有有限 n 达到稳定。限制实例展开不是随意的编译器超时，而是在语言实现中明确拒绝无法产生有限目标程序的泛型展开。

## 为什么 mono 在 sema 前

当前流水线先生成具体 AST，再让常规 sema 检查所有实例；模板本身由 mono 的专门验证器处理。好处是 sema/codegen 主要面对具体类型，复杂度较低。代价是模板验证和常规类型检查存在部分重复，且诊断需要在模板与实例之间定位。

未来引入类型化 HIR 时，可以先对泛型定义做完整类型检查，再在 typed IR 上实例化。对 v0.3 的显式泛型规模，当前结构更直接。

## 推导一次 `choose[int]`

按下面顺序手工追踪：

1. 在模板环境 Delta/Gamma 中证明 `choose` body 合法；
2. 从 `choose[int]` 建立 `{T -> int}`；
3. 替换 prototype、locals、call capability 和 return；
4. 生成 mangled symbol，并把 call site 改到该 symbol；
5. 扫描实例 body，确认没有新 generic need；
6. 让普通 sema 在完全具体的环境中再检查一次；
7. 观察 IR 中只有具体 `i32` signature，没有运行时 T。

这条链把 TAPL 的替换、Ada 式显式约束与编译器的 worklist/mangling 连成同一个过程。
