---
title: 值、类型与机器表示
description: 从静态分类走到位宽、符号和显式转换。
sidebar:
  order: 2
---

pp 是静态类型语言。每个表达式在编译期都有确定类型，赋值、传参和返回都必须满足类型规则。

## 基础类型

| 类型 | pplang 含义 | 典型工程用途 |
|---|---|---|
| `int` | 32 位有符号整数 | 计数、状态码、普通算术 |
| `u8` | 8 位无符号整数 | 字节、字符码、网络缓冲 |
| `u16/u32/u64` | 对应位宽无符号整数 | 协议字段、掩码、地址通道 |
| `float` | 64 位浮点数 | 数值计算 |
| `bool` | `true` 或 `false` | 条件与逻辑运算 |
| `str` | `{ptr,len}` 字节视图 | 文本、协议片段、查询输入 |

```pp
let retries: int = 3;
let ethernet_type: u16 = 2048;
let mask: u32 = 255;
let ratio: float = 0.5;
let ready: bool = true;
let name: str = "pplang";
```

## 类型不是变量上的注释

TAPL 中的类型判断可以读成：“在当前名字环境下，表达式 `e` 具有类型 `T`”。工程上，它意味着编译器在运行前就能拒绝无意义组合：

```pp
let count: int = 3;
let enabled: bool = true;

// count = enabled;     // 错误：int 与 bool 不匹配
// return "three";     // 若函数返回 int，这也是错误
```

类型既限制操作，也决定表示。`u8` 只占一个字节，`u64` 可以作为 64 位地址通道，`str` 则不是单一指针。CSAPP 对数据表示的讨论在这里成为具体语言规则。

## 声明、推断与零值

初始化值足够明确时，可以省略类型：

```pp
let count = 10;       // int
let enabled = false;  // bool
```

没有初始化器时必须写类型，局部变量按类型零初始化：

```pp
let total: u64;
```

推断只省略已经可以唯一确定的信息。它不是动态类型，也不会为泛型调用猜测类型实参。

## bool 不接受整数替代

```pp
// 错误：if (1) { ... }
if (count != 0) {
    println("non-zero");
}
```

C 允许零与非零充当真假，这在底层代码中很方便，也容易让长度、错误码或地址误入条件。pplang 选择严格 bool：逻辑意图必须出现在源码中。

ppdb 的 parser 因此不能把“解析成功”随手编码成任意整数条件；ppos 的设备状态也必须显式比较位或状态码。一个小语义规则会持续改善大程序的可读性。

## 有符号与无符号不是名字差异

同一串位可以按不同方式解释。pplang 对 `int` 使用有符号除法、余数和顺序比较，对 `u8/u16/u32/u64` 使用无符号语义。

```pp
let byte: u8 = 250;
let threshold: u8 = 200;
let high: bool = byte > threshold;
```

在 LLVM IR 中，这会影响比较谓词以及除法、余数指令。类型必须一路传到 codegen，不能只在 parser 后丢掉。

## 转换必须可见

```pp
let wide: u64 = 300;
let byte: u8 = wide as u8;
let number: float = byte as float;
```

跨整数与浮点、整数与指针以及可能收窄的转换使用 `as`。显式转换说明“程序员接受表示变化”，但不保证值没有截断，也不证明一个整数地址可以安全解引用。

## 动手实验

1. 写一个接收 `bool` 的函数，分别传入 `true` 和 `1`，比较结果。
2. 为 `u32` 和 `int` 各写一次 `a / b`，用 `pp ir` 查找对应 LLVM 指令。
3. 把 `300 as u8` 返回，观察截断后的结果，并解释为什么转换语法不等于范围检查。

:::note[理论落点]
TAPL 帮助我们把类型理解为静态判断；CSAPP 帮助我们追问每个类型最终如何占据位和字节。pplang 同时需要这两个视角。
:::
