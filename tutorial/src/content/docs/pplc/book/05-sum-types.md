---
title: 5. 和类型与穷尽检查
description: 从 TAPL 的 tagged union 到 pplc 的 enum、pattern 与控制流。
---

struct 是积类型：一个值同时包含所有字段。enum 是和类型：一个值在若干 variant 中恰好选择一个。TAPL 用类型构造解释这种差别，pplc 则要同时处理静态检查和运行时表示。

```pp
enum Result[T] {
    Ok(T),
    Error(str),
}

fn unwrap_or(value: Result[int], fallback: int) -> int {
    switch (value) {
        Result.Ok(x) => { return x; }
        Result.Error(_) => { return fallback; }
    }
}
```

## Formation、Introduction、Elimination

类型规则通常分三类。Formation 说明怎样构成一个合法类型。若 `T` 和 `str` 都是类型，那么：

```text
T type    str type
──────────────────── F-Result
Result[T] type
```

Introduction 说明怎样构造这种类型。对 `Ok`：

```text
Γ ⊢ e : T
──────────────────────── I-Ok
Γ ⊢ Result.Ok(e) : Result[T]
```

对 `Error` 则要求 payload 是 `str`。这两条规则直接对应 enum constructor 的 arity 和 payload type checking。

Elimination 说明怎样消费一个和类型。`switch` 是 pplang 的 eliminator：每个 arm 假设当前 variant 成立，把 payload 类型加入局部环境，再检查 arm body。核心规则可以写成：

```text
Γ ⊢ e : Result[T]
Γ, x:T   ⊢ ok_arm ok
Γ, m:str ⊢ error_arm ok
all variants covered exactly once
────────────────────────────────── E-Result
Γ ⊢ switch e { ... } ok
```

当前 pp 的 switch 是 statement，因此结论是 arm body 均合法，而不是 switch expression 具有某个统一结果类型；formation/introduction/elimination 的结构仍然成立。

## 构造器检查

`Result.Ok[int](42)` 不是普通函数调用。编译器要：

1. 找到 enum 和 variant；
2. 检查泛型实参数量；
3. 将 variant payload 中的 `T` 替换为 `int`；
4. 检查实参 `42` 的类型；
5. 得到结果类型 `Result[int]`。

unit variant 不允许 payload，带 payload 的 variant 必须恰好得到一个值。尽早在 sema 拒绝 arity/type 错误，能让 codegen 专注于布局。

Applied type 的替换发生在使用 introduction rule 之前。对 `Result.Ok[int](42)`，先把定义中的 T 替成 int，再证明 `42 : int`。如果顺序颠倒，检查器只能拿未知 T 与 int 比较。

## pattern 引入局部 binding

`Result.Ok(x)` 在对应 arm 的 block 中引入 `x: int`。这个 binding 只在 arm 内可见，因此 switch arm 本身也是 scope。`Result.Error(_)` 明确忽略 payload，不创建一个名为 `_` 的普通变量。

pattern typing 可以写成环境扩展函数：

```text
bind(Result.Ok(x), Result[int])    = { x : int }
bind(Result.Error(_), Result[int]) = {}
```

sema 检查 arm 时使用 `Γ + bind(pattern, scrutinee_type)`，退出 arm 后恢复 Γ。这把 pattern matching 与普通 let binding 统一在同一个词法环境模型中。

## 穷尽性是有限集合问题

对于已知 enum，variant 集合是有限的。检查器收集 arm 覆盖的 variant：

- 每个 variant 最多出现一次；
- wildcard 必须放在最后；
- 有 wildcard 时覆盖剩余全部情况；
- 无 wildcard 时，集合必须等于 enum 的完整 variant 集合。

这不是“运行到 default 再处理”的动态策略，而是编译期证明 switch 对每个合法 tag 都有后继控制流。它对应 TAPL 中 canonical forms 与 progress 的工程直觉：一个类型正确的 enum 值进入 switch，不会因为没有匹配分支而卡住。

canonical forms lemma 在这里非常具体：如果一个 closed value 的类型是 `Result[int]`，那么它必须是 `Ok(v)` 且 `v:int`，或者 `Error(m)` 且 `m:str`。不存在第三种由正常 pp 构造器产生的形态。

于是 progress 的 switch 情况可以分两步：canonical forms 告诉我们 tag 必属于有限 variant 集合；exhaustiveness 告诉我们该 tag 一定有 arm。所以求值总能进入一个分支。wildcard 则是对剩余集合的显式覆盖。

## 为什么依赖可靠的表达式类型

若 `typeof_expr` 推断失败就回退成 `int`，穷尽检查可能在错误 enum 上运行，或根本跳过。和类型迫使编译器提高语义层质量：类型查询必须返回 `Result<Type, Error>`，未知不是一种默认类型。

## lowering 概览

LLVM 没有“pplang enum”类型。pplc 将它表示为 tag 加足够容纳最大 variant 的 payload 存储。构造器写 tag 和 payload；switch 读取 tag，建立分支 basic block，并在匹配 arm 中按正确类型读取 payload。

静态穷尽检查与运行时 tag 分派是两件事：前者保证源程序覆盖所有合法 variant，后者实现实际选择。即使检查穷尽，后端仍要生成结构合法的默认/merge 路径来满足 LLVM CFG 约束。

这里存在一个 representation relation：源层 `Result.Ok(42)` 与机器层 `{tag=Ok, payload-bytes=42}` 表示同一抽象值。只有 tag 编号、payload 写入类型和读取类型三者一致，lowering 才保持 introduction/elimination 语义。IR verifier 不知道这个 relation，必须由 pplc 测试守住。

## 测试矩阵

和类型不能只测一次成功解包。当前测试覆盖完整 arms、wildcard、漏分支、重复分支、payload 类型、binding 数量、unit binding、wildcard 顺序和嵌套 sum type。这组测试展示了语言特性应如何从“一个 demo”变成稳定语义。

可以把每个测试重新标注为 F/I/E：泛型实参数量属于 formation，constructor payload 属于 introduction，pattern binding 和穷尽性属于 elimination。这个分类能快速发现某一类规则是否只写了实现、没有覆盖反例。
