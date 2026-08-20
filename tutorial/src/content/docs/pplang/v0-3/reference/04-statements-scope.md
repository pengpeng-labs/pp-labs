---
title: 语句与作用域
description: 声明、赋值、控制流、defer 和返回规则。
sidebar:
  order: 4
---

## 语句

v0.3 支持：

- `let` 普通绑定和 tuple 解构。
- 变量、字段、下标和解引用赋值。
- 表达式语句。
- `if/else if/else`、`while`、`for x in iterable`。
- `switch` enum。
- `break`、`continue`、`return`、`defer`。

除控制流 block 和顶层声明外，语句以分号结束。

## 条件和循环

`if` 与 `while` 必须使用括号并接受 bool。`for` 不使用括号：

```pp
if (ready) { run(); }
while (remaining > 0) { remaining = remaining - 1; }
for item in values { consume(item); }
```

`range(n)`、数组和 str 是 v0.3 支持的遍历来源。`break/continue` 只能在循环中使用。

## 词法作用域

函数体与每个 block 建立独立作用域。名字查找从内到外；内层允许 shadowing，退出 block 后恢复外层绑定。switch 的 payload 名只在对应 arm 的 block 中可见。

## return 与 defer

返回表达式必须与声明返回类型匹配；void 函数使用 `return;` 或自然走到函数末尾。defer 表达式在函数退出点按 LIFO 执行，包括提前 return。v0.3 defer 不以普通 block 退出为触发点。
