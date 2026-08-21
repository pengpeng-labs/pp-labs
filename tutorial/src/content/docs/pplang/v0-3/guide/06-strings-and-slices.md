---
title: str、切片与生命周期
description: 把地址和长度绑定，同时保持所有权责任可见。
sidebar:
  order: 6
---

系统程序经常处理“内存中的一段字节”。只传地址会丢失范围，只依赖 NUL 终止又无法自然表示任意二进制。pplang 的 `str` 是一个不拥有内存的字节视图：

```text
str = { ptr, len }
```

## 长度是值的一部分

```pp
let message: str = "pplang";
let count: u64 = len(message);
let middle: str = message[1:5];
```

`len` 读取已经保存的长度，复杂度是 O(1)。切片使用半开区间 `[lo, hi)`，还支持：

```pp
let tail: str = message[2:];
let head: str = message[:2];
let same: str = message[:];
```

运行时必须满足：

```text
0 <= lo <= hi <= len(message)
```

违反条件会 trap，不会生成越界视图。

## 视图不是所有权

```text
原始内存:  p p l a n g
            └─────────┘ message
                └───┘ middle
```

`middle` 与 `message` 指向同一片底层内存。创建切片不会复制字节，也不会延长底层内存的生命周期。

Zig 的切片文档会同时说明表示、边界和生命周期责任，这是系统语言必须保持的诚实。pplang 没有 borrow checker，因此 API 文档必须回答：

- 这片内存由谁拥有？
- 视图可以使用到什么时候？
- 哪个操作会释放或移动底层缓冲？

## 字节，而不是 Unicode 字符

v0.3 中 str 的长度和索引单位都是字节：

```pp
for byte in "pp" {
    // byte 的类型是 u8
}

let found: bool = 112 in "pplang";
```

pplang 没有字符字面量、Unicode scalar 或 grapheme 抽象。文本协议可以在字节层处理；需要 Unicode 语义时，应由更高层库提供。

## 与裸缓冲互操作

```pp
let view: str = str_from_ptr(buffer, count);
let data: *u8 = str_ptr(view);
```

这两个 builtin 只构造或拆开视图，不复制、不释放、不转移所有权。若 `buffer` 已被释放或长度不真实，`view` 仍然无效。

CSAPP 将指针理解为带类型解释的地址。`str` 在地址之外附带范围信息，却仍不能证明地址有效；它降低一类错误，不声称解决全部内存安全。

## extern 边界

```pp
extern fn write(fd: int, data: *u8, len: u64) -> int;
```

extern 的 str 参数按 C 指针边界处理。目标 API 需要长度时，必须显式声明长度参数；extern 不能返回一个无法确定长度的 str。

ppos 的网络包、TLS record 和 JSON body 都依赖“地址 + 长度”；ppdb 的 SQL 结果和列名也需要明确边界。str 不是为了让字符串语法更现代，而是从系统数据流反推出来的核心表示。

## 动手实验

1. 运行 `tutorial/examples/pplang/strings.pp`。
2. 构造空切片 `s[2:2]`，检查长度。
3. 构造 `s[3:2]` 和超出末尾的切片，观察 trap。
4. 用 `pp ir` 找到 str 的地址与长度字段。

:::caution[常见错误]
从局部数组构造 str 并在函数返回后继续使用，会留下悬垂视图。带长度不等于拥有内存，也不等于自动生命周期安全。
:::
