---
title: 1. 从字符到 Token
description: 词法分类、最长匹配、位置追踪与错误边界。
---

lexer 把字符流分割成 token。龙书会用正规语言、正则表达式、NFA/DFA 建立理论模型；pplc 的词法规模不大，因此用一个确定性的手写扫描器实现同一件事。

```pp
let answer: u32 = value >> 2; // halve twice
```

空白和注释被丢弃，剩下的 token 大致是：

```text
Let Ident("answer") Colon Ident("u32") Assign
Ident("value") Shr Int(2) Semicolon Eof
```

## TokenKind 是词法层的代数数据类型

`lexer.rs` 中的 `TokenKind` 把 token 分成四类：带值的字面量/标识符、关键字、运算符和标点。`Int(i64)` 已经完成十进制或十六进制文本到数值的转换；`Ident(String)` 暂时只知道拼写，还不知道它指向变量、类型还是函数。

这条边界很关键。名称解析依赖作用域，不能塞进 lexer；负数也不是一个特殊整数 token，而是 `Minus` 加 `Int`，交给 parser 构造 unary expression。

## 从正规语言到手写状态机

龙书使用正规表达式描述 token 集合。例如可以把 pp 的两个 token 简化成：

```text
digit      = 0 | 1 | ... | 9
letter     = A | ... | Z | a | ... | z | _
integer    = digit digit*
identifier = letter (letter | digit)*
```

正规表达式可以机械地变换成 NFA，再通过子集构造得到 DFA。pplc 没有在构建时生成 DFA 表，但 `next_token` 的控制流仍是一个确定状态机：当前字符决定进入 identifier、number、string、operator 或 error 分支，每次 `advance` 进行一次状态转移。

以 identifier 为例：

```text
Start --letter--> Ident
Ident --letter/digit--> Ident
Ident --other--> Accept
```

对应实现先用 `is_alphabetic() || c == '_'` 进入分支，再循环消费 `is_alphanumeric() || c == '_'`。接受后还要查关键字表：同样匹配 identifier 正规式的 `fn` 被重新分类为 `TokenKind::Fn`。这叫 reserved-word recognition，不是名称解析。

理论上的好处不是必须写自动机生成器，而是能判断某项需求是否仍属于词法层。例如任意嵌套括号或递归嵌套注释不能由有限状态机单独计数；若语言允许嵌套块注释，手写 scanner 需要额外 depth 状态，已经超出纯 DFA 的有限状态模型。

## 最长匹配

看到 `<` 时，scanner 必须先检查下一个字符，决定是 `Lt` 还是 `Le`；看到 `.` 时要区分 `Dot` 和 `Ellipsis`。这就是最长匹配规则的手写版本。

顺序错误会把 `>>` 切成两个 `Gt`，parser 随后只能报告一个看似无关的语法错误。因此词法测试应覆盖共享前缀：`= ==`、`< <= <<`、`> >= >>`、`& &&`、`| ||`。

龙书把它称为 maximal munch：在仍可能构成合法 token 时继续读取，选择最长可接受前缀。对输入 `>>=`，当前语言没有 `>>=` token，正确结果取决于 token 集合，应是 `Shr Assign`，而不是凭“看起来像复合赋值”创造新 token。

可以用“最后接受状态”理解完整算法：scanner 一边前进一边记录最近一次能接受 token 的位置；若后续字符使状态机无路可走，就回退到最近接受点。pplc 的 token 前缀很简单，多数分支只需 `peek2`，因此没有实现通用回退缓冲。

## 行列位置是诊断基础设施

每个 `Token` 保存起始 `line` 和 `col`。`advance` 在换行时递增行号并把列重置为 1。即使 AST v0.3 还没有把完整 source span 带到后续阶段，lexer 已经为词法和语法错误保留了定位基础。

块注释展示了良好的错误归属：如果扫描到文件尾仍没看到 `*/`，lexer 用注释开始位置报告 `unterminated block comment`。不应让 parser 收到半个注释再猜测。

## Unicode 与工程取舍

当前实现先把源码收集成 `Vec<char>`，位置按 Rust `char` 计数，不按 UTF-8 byte offset。这使教学实现清楚，也允许 Unicode 字母通过 `is_alphabetic` 成为标识符；代价是不能直接用列号做 byte slicing，且 Unicode 标识符规范没有进一步收敛。

工业编译器通常保留 byte range，并另外计算展示列。pplc 当前只需一致地报告位置，未来做 IDE/LSP 时才需要更完整的 span 模型。

## 练习：为 token 写边界表

不要先新增语法。先列出每个 token 的成功与失败边界：

| 输入 | 期望 |
|---|---|
| `0x2a` | `Int(42)` |
| `1.5` | `Float(1.5)` |
| `1.` | 整数后出现 dot，按文法处理或明确报错 |
| `/* x` | 在注释起点报未闭合 |
| `"a\\n"` | 字符串内容按当前 escape 规则解析 |

这类表比“能扫描 hello world”更能守住 lexer 的契约。

再增加一个理论驱动实验：为 identifier、decimal integer 和 `>` 系列运算符各画一个状态机；逐个状态标出接受/非接受，再对照 `next_token`。如果图无法表达当前实现，就说明 token 定义或代码边界至少有一处不清楚。
