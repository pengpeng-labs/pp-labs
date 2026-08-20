---
title: str 与切片
description: 带长度的字节视图、切片边界和所有权边界。
sidebar:
  order: 6
---

`str` 不是 NUL 结尾字符串对象，而是 `{ptr,len}` 字节视图。它知道范围，但不拥有底层内存。

```pp
let message: str = "pplang";
let count: u64 = len(message);
let middle: str = message[1:5];
```

切片是半开区间 `[lo,hi)`，还支持 `s[a:]`、`s[:b]` 和 `s[:]`。运行时必须满足：

```text
0 <= lo <= hi <= len(s)
```

违反边界会 trap，不会生成越界视图。

## 字节，而不是 Unicode 字符

v0.3 的 str 长度和索引单位是字节。`for byte in text` 遍历字节，`112 in text` 检查 ASCII `p` 的字节值。v0.3 没有字符字面量，也没有 Unicode scalar 或 grapheme 抽象。

## 与裸缓冲互操作

```pp
let view: str = str_from_ptr(buffer, count);
let data: *u8 = str_ptr(view);
```

这两个 builtin 只转换视图，不复制数据，也不转移所有权。调用者必须保证底层内存在整个使用期内有效。

:::caution[extern 边界]
extern 的 `str` 参数按 C 指针传递。C API 如果还需要长度，必须把长度作为单独参数声明；extern 不允许直接返回无法确定长度的 `str`。
:::

完整示例位于 `tutorial/examples/pplang/strings.pp`。
