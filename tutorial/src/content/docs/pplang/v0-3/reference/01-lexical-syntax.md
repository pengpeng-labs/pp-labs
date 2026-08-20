---
title: 词法与源文件
description: token、字面量、注释、标识符和顶层声明。
sidebar:
  order: 1
---

## 字符与标识符

源文件扩展名为 `.pp`。空白只分隔 token。标识符满足：

```text
[A-Za-z_][A-Za-z0-9_]*
```

关键字不能作为标识符。v0.3 的关键字为：

```text
fn extern if else return let while for in break continue
struct enum switch import static true false as defer
```

`int`、`float`、`bool`、`str`、`u8`、`u16`、`u32`、`u64` 和 `void` 由类型解析器识别，词法上属于标识符。

## 字面量

- 整数：十进制或 `0x`/`0X` 十六进制，默认类型 `int`。
- 浮点：必须含小数点与小数部分，类型 `float`。
- 布尔：`true`、`false`，类型 `bool`。
- 字符串：双引号形式，产生带长度 `str`。

字符串转义在词法阶段处理。v0.3 没有字符字面量，字节或字符码值使用整数表示。注释支持 `//` 行注释与 `/* ... */` 块注释；块注释不嵌套。

## 顶层项目

源文件由以下项目组成：

```pp
import "relative/path.pp";
extern fn puts(text: str) -> int;
static ticks: u64 = 0;
struct Point { x: int, y: int }
enum Option[T] { Some(T), None }
fn main() -> int { return 0; }
```

`import` 按当前文件目录解析相对路径，递归展开，并按规范化路径去重。它不是包或命名空间机制。
