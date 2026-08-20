---
title: 内存、str 与 ABI
description: 值语义、切片、裸指针、extern 和系统 builtin。
sidebar:
  order: 6
---

## 值与存储

局部标量、数组、tuple、struct 和 enum 采用值语义。复制 aggregate 会复制其表示；如果字段含裸指针或 str，复制的是地址/视图，不会复制所指内存。

堆内存由 stdlib allocator 或宿主环境显式提供。语言没有 GC、析构器或所有权跟踪。

## str

str 是 `{ptr,len}` 字节视图：

- `len(s)` 为 O(1)，返回 u64。
- `s[a:b]` 产生共享底层内存的新视图。
- 必须满足 `0 <= a <= b <= len(s)`，否则 trap。
- `str_from_ptr(ptr,len)` 与 `str_ptr(s)` 不复制、不释放、不转移所有权。

## extern ABI

内部 aggregate 交给 LLVM 目标 ABI。extern 边界采用更窄规则：

- str 参数降为 C 指针；长度必须按目标 API 单独传递。
- extern 不得返回无长度 str。
- tuple 不得用于 extern。
- 泛型声明和实例名不构成 extern ABI。
- variadic extern 只允许末尾 `...`。

复杂 C ABI 应封装在 C 胶水中，对 pp 暴露整数、指针和简单 struct 组成的窄接口。

## 系统 builtin

v0.3 编译器提供 volatile load/store、端口 IO、中断控制、时钟、原子交换和地址转换等目标相关 builtin。它们不是普通跨平台 stdlib API；可用集合取决于构建目标。
