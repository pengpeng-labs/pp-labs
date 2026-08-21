---
title: 9. 表达式、LValue 与内存式 IR
description: alloca/load/store、地址、赋值、cast 与有符号运算的正确 lowering。
---

编译表达式通常产生一个 LLVM value；编译 lvalue 则产生一个地址。这个区分贯穿变量、字段、数组索引、解引用和赋值。

PLAI 在加入 mutable state 后，通常把环境和存储分开：环境 `rho` 把名称映射到 location，store `sigma` 把 location 映射到 value。

```text
rho(x) = lx
sigma(lx) = 40
```

读取 x 是先查 `rho` 得地址，再从 `sigma` load；赋值 x 是保持环境不变，更新 `sigma[lx]`。这正对应 pplc 的 `named_values: name -> alloca` 与 LLVM load/store。

```pp
let x: int = 40;
x = x + 2;
return x;
```

在 pplc 的内存式 lowering 中大致对应：

```llvm
%x = alloca i32
store i32 40, ptr %x
%old = load i32, ptr %x
%next = add i32 %old, 2
store i32 %next, ptr %x
%result = load i32, ptr %x
ret i32 %result
```

可以把两个编译 judgment 分开写：

```text
Gamma ⊢ e => (code, value)       // rvalue lowering
Gamma ⊢ e address => (code, ptr) // lvalue lowering
```

`compile_expr` 实现前者，`compile_lvalue_addr` 实现后者。assignment rule 组合两者：先从 lhs 得到地址，从 rhs 得到值，执行合法 coerce 后 store。

## 为什么 alloca 放 entry block

LLVM 的变量提升 pass 最容易识别 entry-block alloca。即使源语言声明出现在循环内部，编译器也可把栈槽创建在 entry，再在正确控制路径上执行初始化 store。

这不改变词法可见性：作用域表决定名称何时可查，alloca 的物理位置只决定存储生命周期的保守上界。

这也解释 stack allocation 与 lexical scope 不是同一个概念：name 离开 scope 后不可解析，不代表机器 stack pointer 当场回收该 slot。优化器可根据 lifetime/use 再做复用；前端首先保证 binding 语义。

## 读取与写入分开

`compile_expr(Var)` 查地址并 load；`compile_lvalue_addr(Var)` 只返回地址。字段和索引也是同样递归结构。赋值先获得 lhs 地址，再把 rhs coerced 到目标类型并 store。

取地址 `&x` 使用 lvalue 路径；解引用 `*p` 作为值时 load，作为赋值左侧时直接使用 p。把这两条路径混在一起，常见结果是多 load 一次或把值误当地址。

## cast 与 coerce

隐式 coerce 服务于规范允许的上下文转换；显式 cast 服务于 `as`。它们都可能生成整数扩展/截断、整数与浮点转换或 pointer cast，但接受规则不同。

整数扩展必须知道 signedness：`u8 -> u32` 是 zero extension，负数类型的扩展才是 sign extension。LLVM integer type 本身不记录这一点。

从 bit-vector 角度，zero extension 在高位补 0，sign extension 重复最高 sign bit。例如 8 位 `11111111`：

```text
zext -> 00000000 11111111 = 255
sext -> 11111111 11111111 = -1
```

所以扩展指令不是性能细节，而是数值语义的一部分。

## 同一个 i32，不同指令语义

对 `u32`：

- 除法用 `udiv`；
- 余数用 `urem`；
- 大小比较用 `icmp ult/ugt/ule/uge`；
- 右移通常用 logical shift `lshr`。

对有符号 `int` 则对应 `sdiv`、`srem`、signed predicate 和 arithmetic shift。加减乘在补码模运算层面共享指令，但 overflow 语义仍需由语言规范决定。

## 边界检查也是 lowering

对 `s[lo:hi]`，后端要建立：

```text
lo <= len
hi <= len
lo <= hi
```

成功路径构造新的 `{ptr + lo, hi - lo}`，失败路径进入统一 trap/panic 行为。检查不能被省略成“调用者应该正确”，因为 v0.3 规范已把 slice bounds 作为语言承诺。

在 operational semantics 中，可以把越界定义为进入 `trap` 状态，而不是读取任意 memory。lowering 的责任是让所有违反前提的 runtime inputs 都走向同一 trap 行为。只检查 `hi <= len` 而漏掉 `lo <= hi`，就没有实现完整规则。

## 用 IR 测语义

运行结果容易漏掉边界值。对 unsigned lowering，直接断言 IR 包含 `udiv`/`urem`/`icmp ult` 能定位指令选择回归；再用最大位模式做运行测试，覆盖最终行为。结构断言与黑盒行为组合，比单独依赖任何一种更可靠。
