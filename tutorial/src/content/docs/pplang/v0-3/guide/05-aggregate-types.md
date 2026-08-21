---
title: struct、数组与 tuple
description: 用积类型组织数据，并理解值语义与连续布局。
sidebar:
  order: 5
---

基础类型描述单个值，系统程序还需要把多个值组织成记录、定长序列和临时返回结果。TAPL 将这类“同时拥有多个组成部分”的结构称为积类型。

## struct：有名字的积类型

```pp
struct Point {
    x: int,
    y: int,
}

let point: Point = Point { x: 2, y: 3 };
let x: int = point.x;
```

`Point` 的值同时拥有 `x` 和 `y`。字段名属于类型设计的一部分，适合跨函数、跨模块或会继续演进的数据。

```text
Point = int × int
```

这个数学记号不是 pp 语法，而是理解状态空间的方式：如果每个 int 有一组可能值，Point 的可能值就是两组可能值的笛卡尔积。

## 值语义与指针语义

```pp
fn moved(point: Point, dx: int) -> Point {
    point.x = point.x + dx;
    return point;
}
```

struct 参数按值传递，函数修改的是副本。需要修改原对象时接收 `*Point`。如果 struct 内部包含指针或 str，复制 struct 只复制地址或视图，不复制所指内存。

这条规则非常重要：值语义描述“复制表示”，并不自动等于“深拷贝资源”。

## 内存布局不是字段列表的简单相加

CSAPP 和组成原理会讨论对齐与 padding。一个 struct 的字段最终要落在内存中，目标 ABI 可能在字段之间或末尾加入填充。

```pp
struct Header {
    kind: u8,
    length: u32,
}
```

不要仅凭 `1 + 4` 推断 `Header` 的 ABI 大小。使用 `sizeof[Header]()` 和 `alignof[Header]()` 观察具体目标结果；跨 C ABI 时应使用窄胶水并核对双方布局。

## 定长数组：连续的同类型元素

```pp
let values: [3]int = [9, 2, 7];
values[1] = 5;
let count: u64 = len(values);
```

数组类型写成 `[N]T`，N 是编译期整数，也是类型的一部分。`[3]int` 和 `[4]int` 不是同一类型。

数组表示一段连续元素，适合固定协议头、页内 slot、设备描述符和已知上限的缓冲。ppdb 大量使用 `[128]u8`、`[8][32]u8` 这类数组，让容量与静态内存成本可以直接计算。

## tuple：短期匿名积类型

```pp
fn minmax(a: int, b: int) -> (int, int) {
    if (a < b) { return (a, b); }
    return (b, a);
}

let (lo, hi) = minmax(9, 2);
```

tuple 适合少量、局部、含义在调用点已经清楚的组合值。v0.3 不支持嵌套解构、tuple 下标或 extern tuple。

选择规则：

| 场景 | 选择 |
|---|---|
| 固定数量、同类型、按位置访问 | 数组 |
| 字段有稳定业务含义 | struct |
| 少量临时返回值 | tuple |

当 `(bool, int)` 的 bool 和 int 开始代表互斥状态时，不要继续堆 tuple；下一章后的 Sum Type 会提供更可靠的表示。

## 动手实验

1. 运行 `tutorial/examples/pplang/data.pp`，确认 struct 修改与 tuple 解构结果。
2. 对两个字段顺序不同的 struct 使用 `sizeof`/`alignof`，观察目标布局。
3. 尝试把 `[3]int` 赋给 `[4]int`。
4. 在 ppdb 的表目录或页 header 中找一个定长数组，解释它为什么没有使用动态容器。

:::note[理论落点]
TAPL 的积类型解释数据怎样组合；CSAPP 与组成原理解释这些组合最终怎样占据内存。struct、数组和 tuple 分别服务具名记录、连续序列和短期匿名结果。
:::
