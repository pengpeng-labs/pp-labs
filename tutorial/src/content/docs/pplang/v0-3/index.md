---
title: pplang v0.3
description: 一门能装进脑子的系统语言。
sidebar:
  order: 0
---

pp-lang 是一门小型、静态类型、面向系统软件的语言。它保留裸机、指针和 C ABI 所需的能力，同时把字符串长度、词法作用域、Sum Type 和泛型实例写得明确。

v0.3 是第一条适合作为长期教程基座的语言线：v0.2 收紧了类型与内存语义，加入 tuple、Sum Type 和基础容器；v0.3 再加入 Ada 式显式泛型，但没有引入 trait、类型推导或约束求解。

## 三种阅读方式

- 想先理解这门语言为何存在：从[为什么创造 pp](design/01-origin/)开始。
- 想立刻写程序：从[第一个程序](guide/01-getting-started/)开始。
- 已经会写、只想确认规则：进入[语言参考](reference/01-lexical-syntax/)。

## 一个完整的 v0.3 切片

```pp
enum Option[T] { Some(T), None }

fn choose[T](a: T, b: T, less: fn(T, T) -> bool) -> T {
    if (less(a, b)) { return b; }
    return a;
}

fn int_less(a: int, b: int) -> bool {
    return a < b;
}

fn unwrap_or(value: Option[int], fallback: int) -> int {
    switch value {
        Option.Some(v) { return v; }
        Option.None { return fallback; }
    }
    return fallback;
}

fn main() -> int {
    let best: int = choose[int](3, 7, &int_less);
    return unwrap_or(Option.Some[int](best), 0);
}
```

这段程序展示了 v0.3 的核心取向：类型实参必须写出，类型参数不会凭空获得比较能力，所需操作通过普通函数指针显式传入，可能有或没有的值用可穷尽检查的 enum 表达。

:::note[权威边界]
教程负责建立理解；仓库根目录的 `pplang/spec.md` 定义语言。二者不一致时，以 spec 为准并修复教程。
:::
