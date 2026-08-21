---
title: 2. AST 与递归下降 Parser
description: 从具体语法到抽象结构、优先级爬升和局部二义性。
---

PLAI 把 AST 看作语言实现的中心表示：解释器或编译器不是直接理解文本，而是对一种精确的数据结构定义行为。pplc 的 `ast.rs` 因此也是 v0.3 语言能力的一张结构地图。

## 为什么叫“抽象”语法树

源码里的括号、逗号和分号帮助 parser 决定结构，但通常不进入 AST。表达式：

```pp
a + b * c
```

变成：

```text
Binary(Add,
  Var("a"),
  Binary(Mul, Var("b"), Var("c")))
```

树结构已经保存 `*` 比 `+` 优先，后端无需再知道括号规则。

`Type`、`Expr`、`Stmt`、`Item` 是四个主要层次。`Item` 表示顶层声明；`Stmt` 表示产生控制效果的语句；`Expr` 表示求值产生值的结构；`Type` 则描述静态和布局类别。

PLAI 常从“为语言写一个 datatype”开始，因为这个 datatype 决定后续解释器/编译器必须处理的全部情况。Rust 的 exhaustiveness checking 在这里变成课程工具：给 `Expr` 新增 variant 后，所有关键 `match` 都会暴露尚未定义的语义。

## 从文法到调用结构

先看一段简化的 pp 表达式文法：

```text
expr       ::= equality
equality   ::= relation (("==" | "!=") relation)*
relation   ::= additive (("<" | "<=" | ">" | ">=") additive)*
additive   ::= product (("+" | "-") product)*
product    ::= unary (("*" | "/" | "%") unary)*
unary      ::= ("-" | "!" | "~" | "&" | "*") unary | postfix
postfix    ::= primary postfix-op*
```

每一层只引用更高优先级的一层，所以 `product` 会在 `additive` 之前形成子树。`*` 后缀还表达同级运算左结合：读到下一个 `-` 时，把已有 lhs 和新 rhs 组合，再继续循环。

若直接写成：

```text
expr ::= expr "+" term | term
```

它表达左结合很自然，却包含 direct left recursion。递归下降调用 `parse_expr` 后会立刻再次调用自身，永远不消费 token。龙书中的标准变换把它改成：

```text
expr  ::= term expr'
expr' ::= "+" term expr' | epsilon
```

precedence climbing 是把多个这样的优先级层压缩进一个带 `min_prec` 参数的算法。

## 递归下降对应文法层次

`parse_program` 读取 item，`parse_block` 读取语句，`parse_expr` 进入表达式解析。函数之间的调用关系就是文法层次的可执行版本。它的优势是：代码路径直接、容易插入上下文检查、错误点清晰。

表达式使用 precedence climbing：

```text
parse_binary(min_prec)
  lhs = parse_unary()
  while next operator precedence >= min_prec
    rhs = parse_binary(precedence + 1)
    lhs = Binary(operator, lhs, rhs)
```

右侧使用 `prec + 1`，让这些二元运算符左结合。于是 `10 - 3 - 2` 解析为 `(10 - 3) - 2`。

用推导而不是直觉验证：第一次循环构造 `Binary(Sub, 10, 3)`；第二次循环再以整棵旧 lhs 与 `2` 构造外层 `Sub`。如果某运算将来需要右结合，例如赋值或幂运算，就不能盲目使用 `prec + 1`。

## LL(1)、FIRST 与现实中的 lookahead

递归下降最舒服的情况是：看到一个 lookahead token 就知道选哪个 production，也就是 LL(1) 风格。FIRST 集合回答“某个 production 可能以哪些 token 开始”。例如 statement 的 `return`、`let`、`while`、`for` 很容易凭第一个关键字区分。

但 identifier 开头可能是表达式、赋值、函数调用或 struct init。parser 必须先解析共同前缀，再由 `=`、`(`、`{` 等后续 token 决定。pplc 的 `parse_postfix` 和 statement fallback 正是在代码中进行 left factoring 后的结果。

## postfix 为什么单独成层

调用、字段、索引、切片和 cast 都可以连续附着在一个 primary 后面：

```pp
items[i].payload[lo:hi]
```

`parse_postfix` 先得到 `items`，随后循环消费 `[i]`、`.payload` 和 `[lo:hi]`，每次把旧表达式包进一个新节点。这个结构自然表达左到右的访问链。

## `[` 带来的局部尝试

pplang 同时用方括号表示显式类型参数、数组索引/切片和数组字面量。parser 在函数或类型名称后看到 `[` 时，会尝试解析类型实参；如果上下文不成立，再回到表达式路径。

这种局部回溯在小文法中可接受，但必须保持范围小且恢复位置准确。若语言继续增长，最好通过更明确的 token/lookahead 或语法设计消除歧义，而不是无限增加 speculative parsing。

## struct init 与 block 的歧义

`Name { ... }` 可以是结构体初始化，但在 `if condition { ... }` 中，条件后的 `{` 是 block。pplc 用 parser 状态在特定上下文禁止把 `{` 当成 struct init。这是手写 parser 的典型工程问题：文法在纸面上可读，实际解析仍需要上下文决策。

这个状态应被限制在最小作用域并及时恢复，否则一个 `if` 的解析可能污染后续表达式。测试应覆盖 `if flag {}`、`if make() {}` 与真正的 `Point { x: 1 }`。

这里也说明“parser 有状态”不等于文法错误。当前选择用 `no_struct_init` 表达语法上下文；另一种设计是要求 struct init 使用更明确的前导语法。前者保持语言表面简洁，后者减轻 parser 的上下文负担。课程需要把这种取舍展示出来，而不是把 flag 当作偶然实现细节。

## AST 不是类型化 IR

`Expr::Var("x")` 不携带它解析到哪个声明，也不直接保存类型。当前 sema 和 codegen 会维护环境并重新查询。这保持 AST 简单，但也意味着后端承担了部分类型恢复工作。

当诊断、IDE 或优化需求增长时，可以在 parser AST 之后增加 HIR：为节点附 span、resolved symbol id 和完整类型。v0.3 暂不引入它，是规模取舍，不是说这一层没有价值。

## 练习：手工完成一次推导

对 `a + b * c[1]`：

1. 按上面的文法写出 derivation；
2. 画出 AST，确认 Index 在 Mul 内、Mul 在 Add 内；
3. 在 `parse_binary` 中标出每次 `min_prec`；
4. 把表达式改成 `(a + b) * c[1]`，解释 primary 中的括号怎样覆盖优先级。

能在文法、调用栈和 AST 三种表示间来回转换，才算真正理解了手写 parser。
