---
title: 知识来源与语言借鉴
description: 教材提供理论坐标，成熟语言提供工程对照。
sidebar:
  order: 3
---

pplang 有两类来源，不能混为一谈：教材解释一般原理，成熟语言展示不同目标下的工程选择。

## 教材提供什么

| 来源 | 进入 pplang 的知识点 | 在工程中的落点 |
|---|---|---|
| TAPL | 类型判断、作用域、积类型、和类型 | struct、enum、switch、精确类型匹配 |
| PLAI | 通过实现理解语义、逐步扩展语言 | 小型 AST、清楚的降级路径、按需求增加机制 |
| CSAPP | 数据表示、内存、链接、异常控制流 | 整数位宽、指针、ABI、目标文件、系统边界 |
| Computer Organization and Design | 字节序、对齐、内存映射 IO、目标机器 | volatile、端口 IO、freestanding builtin |
| Dragon Book | 前端到 IR 的编译流水线 | 由 pplc 教程展开，pplang 只观察结果 |

TAPL 和 PLAI 并不要求 pplang 采用某种语法；CSAPP 也不会替我们决定字符串类型。它们提供分析问题的词汇与模型，具体边界仍然是 pplang 的设计选择。

## 成熟语言提供什么

| 语言 | 借入 pplang | 有意不借入 |
|---|---|---|
| C | 指针、ABI、手动内存、裸机能力 | 隐式真值、NUL 字符串作为核心模型、宽松转换 |
| Rust | enum 的表达体验、模式穷尽、切片的信息绑定 | borrow checker、trait、生命周期语法 |
| Zig | 显式系统能力、freestanding、切片与责任文档 | comptime、完整指针矩阵、编译期鸭子类型 |
| Go | `[N]T`、直接控制流、方法与指针接收者体验 | GC、interface 与 goroutine 运行时 |
| Python | 教程可读性、`for x in` 与切片直觉 | 动态类型、对象模型和解释器运行时 |
| Ada | 显式泛型实例与所需操作显式声明 | 泛型包体系和更重的约束语法 |
| OCaml | tagged union 与模式匹配 | 高阶模块和复杂模式语言 |

## 三个关键比较

### Rust：保留 Sum Type，不复制所有权系统

Rust 展示了 enum 与 match 如何把互斥状态写得自然。pplang 保留构造、payload 解构和穷尽性，因为这三者共同消除手写 tag 风险；它没有引入 borrow checker，因此 `str` 和指针的生命周期仍由 API 契约负责。

### Zig：保留切片责任，不复制 comptime

Zig 的语言参考会把切片表示、边界检查、所有权与生命周期责任放在一起说明。pplang 采用相同的工程诚实：`str` 是 fat pointer，但不是拥有型字符串。泛型则选择更窄的显式单态化，而不是把类型变成通用编译期值。

### Go：保留直接体验，不引入隐式接口

Go 的教程善于从变量、函数、控制流逐步走到方法和泛型。pplang 借鉴 `[N]T`、方法糖和指针接收者自动取址，但泛型能力通过函数指针显式传入，不由 interface 隐式满足。

## 教程写法也有来源

本教程吸收了成熟官方教程的组织经验：

- Rust Book 的“概念章 + 项目章”。
- A Tour of Go 的短反馈循环和随章练习。
- Python Tutorial 对“教程”与“语言参考”的职责分离。
- Zig Language Reference 对内存表示和生命周期责任的同时说明。

我们不会复制它们的章节或措辞，而是把这种教学结构用于 pplang 的真实实现。

八本教材、相关章节和四个项目之间的详细对应关系见[八本书与 pplang](06-reading-map/)。
