---
title: Sum Type 与穷尽 switch
description: 用类型表达互斥状态，把非法组合排除在程序之外。
sidebar:
  order: 8
---

struct 表达“同时拥有这些组成部分”，enum 表达“只能是这些情况之一”。在类型理论中，它们分别对应积类型和和类型。

## 状态空间的差别

```pp
struct LooseResult {
    ok: bool,
    value: int,
    error: str,
}
```

这个 struct 允许许多含糊状态：`ok=true` 但 error 非空，或者 `ok=false` 却带着看似有效的 value。

```pp
enum Result {
    Ok(int),
    Error(str),
}
```

现在一个值要么是 Ok 并携带 int，要么是 Error 并携带 str。tag 与 payload 由构造器绑定。

## 构造与匹配

```pp
fn divide(a: int, b: int) -> Result {
    if (b == 0) {
        return Result.Error("division by zero");
    }
    return Result.Ok(a / b);
}

switch divide(84, 2) {
    Result.Ok(value) { return value; }
    Result.Error(message) {
        println(message);
        return 1;
    }
}
```

每个变体最多携带一个 payload。复杂 payload 先定义成 struct。无 payload 变体构造时仍使用调用形式：

```pp
enum State { Ready, Failed(str) }
let state: State = State.Ready();
```

## 穷尽性是核心保证

没有 `_` 时，switch 必须覆盖全部变体。不能重复匹配同一变体，`_` 最多一次且必须最后。

穷尽检查带来重要的演进性质：为 enum 增加新变体后，所有依赖完整状态集合的旧 switch 都会在编译期暴露，而不是运行到罕见分支才失败。

这正是 TAPL 中“通过类型排除某类运行时错误”的工程版本。pp 没有实现复杂模式、守卫或嵌套解构，但保留了构造安全、payload 类型和穷尽性。

## 在 ppdb 中的落地

SQL parser 需要表示：

- statement 是 CREATE、SELECT、UPDATE、DELETE 或事务控制之一。
- literal 是整数或文本之一。
- 比较操作是 `= != < > <= >=` 之一。

早期实现使用整数 tag 与裸字段。v0.3 的 `DbStmtKind`、`DbValue` 和 `DbCmpOp` 把状态集合提升到类型层，parser 与 executor 共享同一份受检查表示。

## 运行时表示

pplc 将 enum 表示为稳定的 `i32` tag 加足以容纳最大 payload 的存储，switch 降为 LLVM switch。它不需要 GC 或运行时对象。

表示细节不应被当成任意 extern ABI。跨 C 边界时应使用显式 tag 和窄胶水 struct，并核对布局。

## 动手实验

1. 运行 `tutorial/examples/pplang/sum_type.pp`。
2. 删除一个 switch arm，观察穷尽性诊断。
3. 为 Result 增加 `Retry(int)`，更新所有调用点。
4. 把 parser 风格的 `(tag, int, str)` 改写成 enum，比较能表达的非法状态数量。

:::note[理论落点]
TAPL 提供和类型与类型安全的模型；Rust/OCaml 展示了 enum 与模式匹配的工程体验；ppdb 证明这不是装饰语法，而是消除真实 tag/payload 风险的机制。
:::
