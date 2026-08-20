---
title: 接下来读什么
description: 从会写 pp 走向编译器、数据库和操作系统。
sidebar:
  order: 11
---

完成本教程后，你应当能够：

- 写出包含函数、作用域、struct、数组、tuple 和切片的程序。
- 用 enum 表达状态，并依赖穷尽 switch 维护分支。
- 用显式泛型复用类型结构，用函数指针传递所需能力。
- 区分普通值、非拥有 str 视图、标准库容器和裸指针。
- 判断一项能力属于核心语言、stdlib、FFI 还是目标 builtin。

下一步取决于你想追哪条线：

- 想确认精确规则：继续读[参考手册](../reference/01-lexical-syntax/)。
- 想知道泛型和 Sum Type 如何实现：等待 pplc 教程，或直接阅读 `pplc/src/mono.rs`、`sema.rs` 与 `codegen.rs`。
- 想看语言进入真实系统：ppdb 展示存储与查询，ppos 展示 freestanding 与硬件边界。

语言学习到这里告一段落，但规范仍是最终裁决者。遇到教程没有覆盖的边角行为，不要根据其他语言类推，先查参考手册和 `pplang/spec.md`。
