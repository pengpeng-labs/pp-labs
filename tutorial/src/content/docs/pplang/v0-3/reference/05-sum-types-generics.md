---
title: Sum Type 与泛型规则
description: enum、switch、显式实例化和模板限制。
sidebar:
  order: 5
---

## enum 与 switch

enum 变体可以无 payload，或携带一个 payload：

```pp
enum Option[T] { Some(T), None }
```

构造形式为 `Option.Some[int](1)` 和 `Option.None[int]()`。匹配形式省略类型实参：

```pp
switch value {
    Option.Some(item) { use(item); }
    Option.None { handle_none(); }
}
```

规则：

- switch 值必须是 enum。
- payload 只支持一个名字的单层绑定。
- 无 `_` 时必须覆盖全部变体。
- 同一变体不能重复。
- `_` 最多一次且必须最后。
- payload 名只在 arm block 内可见。

enum 表示为稳定 i32 tag 加 payload storage；具体布局属于目标 ABI，不能作为 extern 通用协议。

## 泛型声明与实例

```pp
fn f[T](value: T) -> T
struct Pair[A, B] { first: A, second: B }
enum Result[T, E] { Ok(T), Error(E) }
```

所有使用点必须提供完整类型实参。具体实例是独立名义类型，嵌套实例合法，相同实例只生成一次。

## 模板限制

类型参数不隐式获得算术、比较、转换或条件能力。模板需要的操作必须通过普通值或函数指针参数传入。泛型在 sema/codegen 前单态化，递归产生不断变化的新实例会被拒绝。

`sizeof[T]()` 与 `alignof[T]()` 只接受一个类型实参、零个值实参，返回编译期 `u64`。extern 函数不能泛型，泛型实例名也不构成稳定 extern ABI。
