---
title: 值与类型
description: 基础类型、声明、推断与显式转换。
sidebar:
  order: 2
---

pp 是静态类型语言。每个表达式在编译期都有确定类型，赋值、传参和返回都必须满足类型规则。

## 基础类型

| 类型 | 含义 |
|---|---|
| `int` | 32 位有符号整数 |
| `u8/u16/u32/u64` | 对应宽度的无符号整数 |
| `float` | 64 位浮点数 |
| `bool` | `true` 或 `false` |
| `str` | 不拥有内存的 `{ptr,len}` 字节视图 |

```pp
let retries: int = 3;
let mask: u32 = 255;
let ratio: float = 0.5;
let ready: bool = true;
let name: str = "pp";
```

初始化值足够明确时，可以省略类型：

```pp
let count = 10;
let enabled = false;
```

没有初始化器的局部变量按其类型零初始化，但公开代码应当只在确实需要“先声明、后赋值”时使用它。

## bool 不接受整数替代

```pp
// 错误：if (1) { ... }
if (count != 0) {
    println("non-zero");
}
```

严格 bool 让条件的意图明确，也阻止指针、长度或状态码意外进入分支。

## 转换必须可见

```pp
let wide: u64 = 300;
let byte: u8 = wide as u8;
let address: u64 = ptr_to_int(str_ptr(name));
```

跨整数与浮点、整数与指针以及可能收窄的转换使用 `as`。无符号除法、余数和大小比较遵守无符号语义，不借用 `int` 的有符号指令。
