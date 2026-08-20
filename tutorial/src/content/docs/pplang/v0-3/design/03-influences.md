---
title: 借鉴了哪些语言
description: pp 如何按问题借思想，而不是拼接语法。
sidebar:
  order: 3
---

pp 的设计不是语言特性拼盘。每项借鉴都有明确问题，也有明确停止线。

| 来源 | 借入 pp | 没有借入 |
|---|---|---|
| C | 指针、ABI、手动内存、裸机能力 | 隐式真值、NUL 字符串模型、宽松转换 |
| Rust | 表达式可读性、enum 的使用体验 | borrow checker、trait、生命周期语法 |
| Zig | 显式系统能力、freestanding 取向、切片思想 | comptime、完整指针类型矩阵 |
| Go/Python | `for x in s`、`range(n)`、切片的直观写法 | GC、动态类型和大型运行时 |
| OCaml/TAPL | tagged union、payload 解构、穷尽检查 | 高阶类型系统和复杂模式语言 |
| Ada | 泛型显式实例化、依赖能力显式声明 | 重型泛型包与约束语法 |
| Lua | 少 feature、多 mechanism | 动态 table、metatable 和反射运行时 |
| LLVM Kaleidoscope | 小步理解编译器前端的方法 | 只停留在表达式玩具语言 |

## C：保留能力，收紧默认语义

pp 与 C 一样允许程序直接接触地址、外部函数和硬件。但 `if (1)` 在 pp 中是错误，整数宽度和符号语义受类型约束，字符串携带长度。pp 不是“换语法的 C”，而是保留 C 能力后重新选择默认规则。

## OCaml 与 TAPL：Sum Type 的命根子是穷尽性

只实现 `{tag,payload}` 布局并不够。真正消除手写 tag 风险的是：构造器决定 payload 类型，switch 必须覆盖全部变体。pp 砍掉嵌套模式、守卫和多 payload 语法，却保留这条核心保证。

## Ada：显式泛型，而非隐式能力

Ada 泛型会显式声明算法所需操作。pp 将这个思想降到已有机制：类型复用由 `fn f[T]` 提供，操作约束由普通函数指针参数提供。这样不需要 trait solver，也没有隐藏的候选查找。

## Zig：显式不是语法越多

pp 接受 Zig 的系统设计取向，却没有复制它的全部指针和编译期元编程体系。pp 的显式意味着关键资源与能力在程序文本里可见，不意味着为每种情况创造一种新类型。
