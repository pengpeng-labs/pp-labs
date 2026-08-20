---
title: struct、数组与 tuple
description: 用积类型组织数据，用 tuple 返回少量匿名结果。
sidebar:
  order: 5
---

## struct

struct 是具名、值语义的字段集合：

```pp
struct Point {
    x: int,
    y: int,
}

let point: Point = Point { x: 2, y: 3 };
let x: int = point.x;
```

构造时显式写出字段名。需要组合长期存在或有业务含义的数据时，优先使用 struct。

## 定长数组

数组类型使用长度前置语法 `[N]T`：

```pp
let values: [3]int = [9, 2, 7];
values[1] = 5;
let count: u64 = len(values);
```

长度是类型的一部分，必须在编译期确定。旧语法 `[T; N]` 不属于 v0.3。

## tuple

tuple 用于少量、局部、无需字段名的组合值，最常见用途是多返回值：

```pp
fn minmax(a: int, b: int) -> (int, int) {
    if (a < b) { return (a, b); }
    return (b, a);
}

let (lo, hi) = minmax(9, 2);
```

v0.3 不支持嵌套解构、tuple 下标或 extern tuple。数据一旦需要名字、跨越 API 边界或继续演进，就应改成 struct。

完整组合示例位于 `tutorial/examples/pplang/data.pp`。
