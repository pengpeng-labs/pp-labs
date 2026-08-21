---
title: Buf、Vec 与 StrMap
description: 用现有语言机制构造容器，并明确容量与所有权。
sidebar:
  order: 10
---

语言核心不应该为每种数据结构增加语法。pplang 用 struct、指针、allocator、方法糖和显式泛型，在标准库中构造三类容器。

## 从数组和切片出发

```text
[N]T    地址 + 编译期长度，存储固定
str     地址 + 运行时长度，不拥有字节
Buf     地址 + 长度 + 容量，拥有 u8
Vec[T]  地址 + 长度 + 容量，拥有 T 序列
StrMap  slot 地址 + 数量 + 容量，拥有键值副本
```

CSAPP 对连续内存和动态分配的讨论，在容器里变成三个具体问题：当前有多少元素、分配了多少空间、扩容后旧地址是否仍然有效。

## Buf：可增长字节缓冲

```pp
import "../../../stdlib/buf.pp";

let out: Buf = buf_new(16);
defer out.buf_free();

out.buf_append("hello");
out.buf_push(33 as u8);
let view: str = out.buf_view();
```

Buf 服务 HTTP、JSON、TLS 和查询结果等字节流。长度追上容量时，`buf_reserve` 分配更大区域、复制旧数据并释放旧区域。

因此，扩容前取得的 `str` 视图可能在下一次 push 后失效。切片的生命周期依赖容器是否移动底层内存。

## Vec[T]：泛型连续序列

```pp
import "../../../stdlib/vec.pp";

let values: Vec[int] = vec_new[int]();
defer values.vec_free[int]();

values.vec_push[int](10);
values.vec_push[int](20);
let second: int = values.vec_get[int](1);
```

`Vec[T]` 使用 `sizeof[T]()` 计算元素大小，使用显式实例化生成具体容器代码。方法调用自动把可取址的 `values` 变成 `*Vec[int]`。

这里没有自动析构。如果 T 内含需要释放的资源，`vec_free` 只释放元素存储，不会逐个理解并清理 T。

## StrMap：领域化容器

```pp
import "../../../stdlib/strmap.pp";

let config: StrMap = map_new(8);
defer config.map_free();

config.map_set("theme", "dark");
let (found, value) = config.map_get("theme");
```

StrMap 使用 FNV-1a 哈希、开放寻址和扩容。它固定为 `str → str`，因为配置、协议和 ppdb 边界确实大量使用字节串。

为什么不立刻做 `Map[K,V]`？泛型 K 还需要哈希、相等、复制和释放能力。pplang 可以通过函数指针显式传入，但当前需求不足以证明这层复杂度。领域化容器有时比万能抽象更合适。

## 容器 API 的责任表

| 操作 | 可能分配 | 可能使旧视图失效 | 谁释放 |
|---|---:|---:|---|
| `buf_push/append` | 是 | 是 | `buf_free` |
| `vec_push[T]` | 是 | 是 | `vec_free[T]` |
| `map_set` | 是 | 是 | `map_free` |
| `buf_view` | 否 | 否，但后续扩容会 | 容器仍拥有 |
| `map_get` | 否 | 后续修改/扩容可能会 | map 仍拥有 |

这张表比“内存安全”四个字更有用：没有 borrow checker 时，API 必须明确分配、失效和释放责任。

## 为什么属于标准库

这些容器完全由 v0.3 已有机制实现，不需要改变语言求值规则或类型系统。把它们留在 stdlib 有三个好处：

1. 数据结构可以独立演进。
2. 教程可以直接阅读其实现。
3. 语言核心不因每个常用容器膨胀。

## 动手实验

1. 运行 `tutorial/examples/pplang/vec.pp` 和 `collections.pp`。
2. 阅读 `stdlib/buf.pp` 的扩容路径，标出旧指针失效的位置。
3. 为 Vec 写一个 `vec_sum`，解释为什么它只能用于 `Vec[int]`，或需要怎样的显式能力参数。
4. 为 StrMap 插入足够多的键触发扩容，再检查已有键。

:::note[理论落点]
类型与泛型提供可复用结构；CSAPP 提供内存和分配模型；真实协议、数据库与配置场景决定哪些容器值得存在。这里体现的是“语言机制 + 库设计”，不是新增语法。
:::
