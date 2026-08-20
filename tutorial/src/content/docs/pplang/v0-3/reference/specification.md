---
title: v0.3 规范与兼容性
description: 规范权威、版本规则和实现一致性。
sidebar:
  order: 0
---

本参考手册是 pplang v0.3 规范的教学化索引。语言的唯一权威文本是仓库中的 [`pplang/spec.md`](https://github.com/pengpeng-labs/xlc-lang/blob/main/pplang/spec.md)。设计动机记录在 [`pplang/design.md`](https://github.com/pengpeng-labs/xlc-lang/blob/main/pplang/design.md)。

## 版本基线

v0.3 定版提交发布时使用 Git tag `pplang-v0.3.0` 固定代码与规范基线。版本规则如下：

- v0.3.x 可以修复编译器缺陷、改善诊断、补测试和澄清文字。
- 新增语法、改变既有程序含义或删除能力，必须进入后续语言版本。
- 教程示例由当前仓库编译器持续验证；教程与 spec 冲突时，修教程而不是默默改变规范。

## 文档职责

| 文档 | 职责 |
|---|---|
| `spec.md` | 规定语法、类型和可观察语义 |
| `design.md` | 解释来源、历史、取舍与明确不做 |
| 使用教程 | 建立从简单程序到系统边界的学习路径 |
| 参考手册 | 让已经会用的读者快速查规则 |
| pplc 测试 | 验证实现对正例与反例的行为 |

## v0.3 核心边界

v0.3 包含值语义复合类型、裸指针、函数指针、Sum Type、显式泛型和 hosted/freestanding 输出。它不包含 GC、所有权、borrow checker、trait/interface、泛型推导、comptime、宏、异常、源码级 unsafe/asm 或包管理。
