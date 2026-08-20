---
title: 显式泛型
description: 类型参数、能力参数、单态化和 Vec[T]。
sidebar:
  order: 9
---

v0.3 允许函数、struct 和 enum 声明类型参数，但每次使用都必须写全类型实参。

```pp
fn identity[T](value: T) -> T {
    return value;
}

let answer: int = identity[int](42);
```

没有 `identity(42)` 的推导形式。显式调用让实例类型和生成代码一眼可见。

## 类型参数没有隐式能力

下面的模板不合法，因为未知 `T` 没有自动获得 `<`：

```pp
// fn larger[T](a: T, b: T) -> T {
//     if (a < b) { return b; }
//     return a;
// }
```

把所需操作变成普通参数：

```pp
fn larger[T](a: T, b: T, less: fn(T, T) -> bool) -> T {
    if (less(a, b)) { return b; }
    return a;
}

let best: int = larger[int](6, 9, &int_less);
```

这就是 pp 的受约束泛型：类型复用由 `[T]` 提供，能力约束由函数类型提供，不需要 trait solver。

## 泛型数据类型

```pp
enum Option[T] { Some(T), None }

struct Pair[A, B] {
    first: A,
    second: B,
}
```

`Option[int]` 与 `Option[str]` 是不同的具体名义类型。支持 `Option[Vec[int]]` 这样的嵌套实例。构造也写显式类型参数：`Option.Some[int](1)`。

## 单态化

编译器在语义分析和 codegen 前，将每组实际类型展开为普通 AST 实例；相同实例只生成一次。泛型没有运行时类型对象，也不能形成泛型 extern ABI。

`sizeof[T]()` 和 `alignof[T]()` 在具体实例中产生编译期 `u64` 常量。标准库 `Vec[T]` 用它们计算元素布局。

完整示例位于 `tutorial/examples/pplang/generics.pp` 与 `vec.pp`。
