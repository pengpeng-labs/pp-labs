---
title: pplang v0.3
description: 从语言概念到系统工程，完整学习 pplang v0.3。
sidebar:
  order: 0
---

**pplang，简称 pp**，是一门小型、静态类型、面向系统软件的语言。`.pp` 源码既可以在宿主机上 JIT 运行或编译为可执行文件，也可以生成目标文件和 freestanding 裸机产物。

这不是一份语法清单。课程要回答三个彼此关联的问题：

1. 一段 pp 程序怎样写，它的精确语义是什么？
2. TAPL、PLAI、CSAPP 与计算机组成原理中的概念，怎样成为语言机制？
3. 这些机制怎样在 pplc、ppdb 和 ppos 的真实代码中承受压力？

## 学完以后

你将能够：

- 使用值、函数、控制流、struct、数组、tuple、enum 和显式泛型组织程序。
- 区分积类型与和类型、值与地址、拥有内存与非拥有视图。
- 解释严格 bool、词法作用域、穷尽 switch 和显式能力参数解决了什么问题。
- 使用指针、allocator、FFI 和 volatile，同时说清楚责任边界。
- 阅读 `pp ir` 产生的 LLVM IR，并把语言规则与机器表示联系起来。
- 判断一项能力应该进入语言、标准库、编译器 builtin，还是 C/汇编胶水。

## 课程路径

课程分成三层，职责刻意分开：

| 部分 | 回答的问题 | 阅读方式 |
|---|---|---|
| 来源与设计 | 为什么有 pplang，为什么停在 v0.3 | 先建立全局判断 |
| 使用教程 | 怎样描述并使用语言，概念怎样进入工程 | 按顺序阅读并运行实验 |
| 参考手册 | 某条语法和语义的准确规则是什么 | 按需查阅 |

使用教程采用“概念章 + 工程实验”的结构。每章都会把理论坐标、pp 代码、编译结果和仓库中的真实使用点放在一起。最后的综合实验会组合切片、struct、Sum Type 与显式泛型，而不是再写一个孤立的 Fibonacci。

## 理论怎样进入语言

```text
TAPL / PLAI                 CSAPP / 组成原理
类型、作用域、积与和类型      数据表示、地址、ABI、目标机器
          \                  /
           \                /
              pplang v0.3
                   |
        pplc / ppdb / ppos 的真实约束
```

- TAPL 给出类型、作用域、积类型、和类型与类型安全的语言。
- PLAI 强调通过构造语言理解语义，而不是只背语法。
- CSAPP 把整数表示、内存、链接、异常控制流和系统接口连起来。
- 计算机组成原理解释字节、对齐、调用约定、MMIO 与指令选择为何存在。

这些书提供理论坐标；pplang 的设计仍来自作者对教学复杂度、系统能力和 LLM 生成稳定性的观察。课程会明确区分“书中的一般原理”和“pp 做出的具体取舍”。

## 先看一个 v0.3 程序

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
        Option.Some(item) { return item; }
        Option.None { return fallback; }
    }
    return fallback;
}

fn main() -> int {
    let best: int = choose[int](3, 7, &int_less);
    return unwrap_or(Option.Some[int](best), 0);
}
```

这段代码包含 v0.3 的核心判断：类型实参必须写出，未知类型不会自动获得比较能力，行为通过函数指针显式传入，互斥状态由 enum 表达，并由 switch 检查穷尽性。

:::note[命名约定]
语言和项目统一称为 **pplang**，简称 **pp**；源码扩展名是 `.pp`，编译器项目是 **pplc**，编译器命令同样是 `pp`。
:::

:::note[权威边界]
教程负责建立理解；仓库中的 `pplang/spec.md` 定义 v0.3 语法和可观察语义。两者不一致时，以规范为准并修复教程。
:::

从[为什么创造 pplang](design/01-origin/)开始理解设计；准备系统学习时，先读[如何描述一门语言](guide/00-language-model/)，再运行[第一个 pp 程序](guide/01-getting-started/)。八本教材与具体章节的对应关系集中在[阅读地图](design/06-reading-map/)。
