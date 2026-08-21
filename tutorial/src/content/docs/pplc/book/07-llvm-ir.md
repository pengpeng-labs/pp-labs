---
title: 7. LLVM IR 基础
description: Module、Function、BasicBlock、Instruction、SSA 与终结指令。
---

LLVM IR 不是可移植汇编文本的简单别名。它是一种带静态类型、SSA 值和显式控制流图的中间表示。Inkwell 构造的是 LLVM 对象；`pp ir` 只是把 module 打印成便于阅读的文本。

## 从 AST 到三地址代码

龙书常先引入 three-address code：每条指令至多包含一个主要运算，复杂表达式拆成临时值。

```pp
return a + b * c;
```

可以翻译成：

```text
t1 = b * c
t2 = a + t1
return t2
```

AST 表达嵌套语法，三地址表示把求值顺序显式化。LLVM IR 延续这一思想，但临时值带类型，控制流形成 basic block，并受 SSA 约束。`compile_expr` 的递归返回值正是语法制导翻译属性：先得到 children 的 LLVM values，再用 Builder 产生 parent operation。

## 四层对象

一个 pplc `Codegen` 持有三件核心对象：

- `Context`：拥有 LLVM 类型和常量的上下文；
- `Module`：一个编译单元，包含函数、global、target 信息；
- `Builder`：在当前 basic block 的插入点创建 instruction。

Module 中的函数由 basic block 组成，basic block 由 instruction 顺序组成。每个 block 必须以 terminator 结束，例如 `ret`、`br` 或 `switch`。

```llvm
define i32 @abs(i32 %x) {
entry:
  %is_neg = icmp slt i32 %x, 0
  br i1 %is_neg, label %negative, label %positive

negative:
  %neg = sub i32 0, %x
  ret i32 %neg

positive:
  ret i32 %x
}
```

## 从线性指令到 CFG

basic block 是单入口、控制只从末尾离开的最大直线序列。传统 leader 算法把函数切块：入口是 leader，跳转目标是 leader，跳转后的下一条指令也是 leader。

把 block 当作 vertex、branch 当作 edge，就得到 control-flow graph。对上面的 `abs`：

```text
entry -> negative
entry -> positive
```

CFG 让“所有路径是否 return”“某块是否可达”“循环在哪里”“值在哪些路径上定义”等问题变成图问题。pplc 直接以 structured AST 构造 CFG，不需要先生成 label 指令再切块，但产物必须满足相同性质。

## SSA 值

SSA 要求每个虚拟寄存器只定义一次。`%is_neg` 和 `%neg` 都不会被重新赋值。如果两个控制流分支产生不同值并在 merge block 合流，纯 SSA 通常用 `phi` 选择来自哪个前驱。

pplc v0.3 为局部变量采用 entry-block `alloca`：赋值生成 `store`，读取生成 `load`。这样 shadowing、循环赋值和取地址都容易实现。代价是 IR 较冗余，优化器需要把可提升的栈变量转换为 SSA。

phi 的位置不是随便选择。若 block D 位于从 entry 到 block B 的每条路径上，则 D dominates B。一个变量在不同分支被定义、随后在 merge 使用时，需要在定义路径的 dominance frontier 放 phi：

```llvm
then:  br label %merge
else:  br label %merge
merge:
  %x = phi i32 [1, %then], [2, %else]
```

手工维护 dominator/phi 会显著增加前端复杂度。pplc 先把 mutable local lowering 成 stack slots，再让 mem2reg 计算 dominance 并提升适合的 alloca，是经典的教学与工程折中。当前 O0 不运行该 pass，所以 `pp ir` 展示的是提升前形式。

## LLVM 类型不等于源类型

`int` 和 `u32` 都可能 lowering 为 `i32`；signedness 存在于选择的 operation，而不在 `i32` 类型中。`bool` lowering 为 `i1`，但 ABI 或内存布局可能需要额外考虑。`str` 在语言层是 address + length，当前 64 位地址模型将它 lowering 为 `{i64, i64}`。

因此不能从 `BasicTypeEnum` 完整反推 pplang `Type`。pplc 保留源类型表来决定 unsigned division/comparison、字段布局和 builtin 行为。

## opaque pointer

LLVM 18 使用 opaque pointers：IR 中主要看到 `ptr`，pointer 本身不再编码 pointee type。load、store、GEP 等指令必须由调用方提供操作类型。

这使一个事实更明显：前端必须知道 `*T` 中的 T。Inkwell 的 pointer value 不能替代源语言的 pointee type 环境，`var_types`、函数签名与 lvalue type 查询仍是必要的。

## verifier 的角色

LLVM verifier 检查 module 的结构合法性，例如：

- block 是否有 terminator；
- instruction operand 类型是否匹配；
- phi incoming block 是否合理；
- return 类型是否符合函数签名。

它不能检查 `u32` 是否错误使用 `sdiv`，因为两者对 LLVM 都是合法 `i32` 运算。结构正确与源语义正确必须分别测试。

可以把验证分成两层：

```text
LLVM well-formedness: verifier(module) = ok
source preservation: behavior(AST) = behavior(module)
```

第一层由 LLVM 提供算法；第二层由 pplc 的类型信息、lowering 设计、IR assertions 与运行测试共同建立。不要因为 module 能通过 verifier，就声称编译器语义正确。

## 阅读 IR 的顺序

先看 function signature，再列 basic blocks 和 terminator，最后追踪具体值。不要从临时编号逐行硬读。对每个 source construct，问三个问题：产生哪些 block、值在哪里定义、每条路径在哪里终止。
