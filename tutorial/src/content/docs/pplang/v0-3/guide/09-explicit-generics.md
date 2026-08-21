---
title: 显式泛型与能力参数
description: 用类型参数消除重复，用普通函数显式表达约束。
sidebar:
  order: 9
---

泛型解决的是结构性重复：算法或数据结构相同，只是其中某个类型不同。

## 从重复开始

```pp
fn identity_int(value: int) -> int { return value; }
fn identity_u64(value: u64) -> u64 { return value; }
```

把变化的类型抽成参数：

```pp
fn identity[T](value: T) -> T {
    return value;
}

let answer: int = identity[int](42);
let address: u64 = identity[u64](4096 as u64);
```

v0.3 每次使用都必须写完整类型实参，没有 `identity(42)` 的推导形式。调用点因此能直接读出具体实例。

TAPL 将这种能力称为参数多态：函数对任意 T 使用同一结构，而不依赖 T 的具体内容。

## 未知 T 没有隐式运算

下面的模板不合法：

```pp
// fn larger[T](a: T, b: T) -> T {
//     if (a < b) { return b; }
//     return a;
// }
```

`T` 没有自动获得 `<`。把需要的能力变成参数：

```pp
fn larger[T](a: T, b: T, less: fn(T, T) -> bool) -> T {
    if (less(a, b)) { return b; }
    return a;
}

fn int_less(a: int, b: int) -> bool {
    return a < b;
}

let best: int = larger[int](6, 9, &int_less);
```

Ada 的显式泛型会声明模板依赖的操作。pplang 把这个思想压到已有语言机制：类型复用用 `[T]`，操作约束用函数指针。不需要 trait solver，也没有隐藏候选查找。

## 泛型 struct 与 enum

```pp
struct Pair[A, B] {
    first: A,
    second: B,
}

enum Option[T] {
    Some(T),
    None,
}
```

`Pair[int,str]`、`Option[int]` 和 `Option[str]` 都是独立具体名义类型。构造泛型 enum 也写出类型实参：

```pp
let value: Option[int] = Option.Some[int](7);
let empty: Option[int] = Option.None[int]();
```

## 单态化：泛型最终仍是具体代码

pplc 为每组类型实参建立具体 AST 实例：

```text
identity[int]  → 接收 int 的具体函数
identity[u64]  → 接收 u64 的具体函数
```

相同实例只生成一次。运行时不携带通用类型对象，也没有动态分派成本；代价是实例过多可能增加编译时间和代码体积。递归产生无限不同类型实例会被编译器拒绝。

`sizeof[T]()` 和 `alignof[T]()` 在具体实例中成为编译期常量，标准库 `Vec[T]` 用它们计算元素步长与分配大小。

## 和 Rust、Go、Zig 的区别

| 语言 | 约束方式 | pplang 的选择 |
|---|---|---|
| Rust | trait bounds | 不引入 trait，实现作为函数参数 |
| Go | type set/interface constraint | 不做约束集合和类型推断 |
| Zig | comptime 类型和编译期鸭子类型 | 不引入通用 comptime |
| Ada | 显式实例与形式操作 | 借用显式思想，使用较轻语法 |

## 动手实验

1. 运行 `generics.pp` 和 `vec.pp`。
2. 尝试省略 `[int]`，记录诊断。
3. 为 `larger` 传入相反比较函数，观察“能力作为值”的效果。
4. 分别生成 `identity[int]` 与 `identity[u64]` 的 IR，查找两个实例。

:::caution[泛型不自动带来正确资源管理]
`Vec[T]` 能按 T 的大小分配和复制元素，但若 T 内含拥有型指针，语言不会自动深拷贝或析构。泛型复用类型结构，不替代所有权契约。
:::
