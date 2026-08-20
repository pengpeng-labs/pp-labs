---
title: 编译命令与诊断
description: pp CLI、产物和常见静态错误。
sidebar:
  order: 7
---

## CLI

```text
pp ir    <file>
pp run   <file>
pp build <file> [-o output]
pp obj   <file> [-o output.o]
pp os    <file> [-o output]
```

| 命令 | 行为 |
|---|---|
| `ir` | 输出 LLVM IR |
| `run` | JIT 执行 main，并打印返回值 |
| `build` | 生成并链接宿主机可执行文件 |
| `obj` | 生成目标文件，由外部链接器继续处理 |
| `os` | 生成 x86_64 freestanding 裸机目标 |

v0.3 CLI 没有 package、workspace、lockfile 或依赖下载能力。

## 必须诊断的错误类别

- 未定义名字、同作用域重复变量、同名函数重复定义。
- 参数数量/类型、返回类型和赋值类型不匹配。
- 非 bool 条件或逻辑运算。
- 旧 `[T; N]` 数组语法。
- 非 enum switch、漏变体、重复 arm、错误 payload 绑定。
- 泛型调用缺少类型实参、实参数量错误、模板对 T 使用未声明能力。
- 泛型递归产生无限不同实例。
- extern 使用不允许的 str 返回、tuple 或泛型 ABI。

诊断文本不是 v0.3 的稳定 API，但错误类别和拒绝行为属于规范的一致性要求。
