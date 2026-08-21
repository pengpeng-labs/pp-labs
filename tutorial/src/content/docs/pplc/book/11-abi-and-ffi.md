---
title: 11. 函数、ABI 与 FFI
description: prototype、调用、extern、varargs、str 边界与函数指针。
---

函数调用横跨静态类型、LLVM signature 和平台 ABI。只要调用者与被调用者对任一项理解不同，module 可能验证通过，程序仍会在运行时损坏数据。

## 从函数语义到 activation record

语言层调用可以描述为：求值 arguments，建立 parameter bindings，执行 body，得到 return value，再回到 continuation。CSAPP 和龙书的 runtime environment 把它落实为 calling sequence 与 activation record：

```text
caller evaluates arguments
  -> arguments placed in ABI locations
  -> call transfers control and records return address
  -> callee establishes frame / locals
  -> return value placed in ABI location
  -> control returns to caller
```

真实 ABI 会把部分参数放寄存器、部分放栈，规定哪些 register 由 caller/callee 保存，并处理 stack alignment。LLVM call instruction 描述 typed call，target backend 再按 calling convention 完成机器级分配。

## prototype 先于 body

`Prototype` 包含名称、类型参数、参数、返回类型和 varargs 标志。codegen 先把所有 prototype 注册到 module，并保存 pplang 层的参数/返回类型；编译 call 时据此检查和 coerce argument。

普通函数 lowering 为 LLVM `fn_type`。tuple/struct 返回、聚合参数和 varargs 最终如何放进寄存器或栈，由目标 ABI 决定。LLVM target backend 能处理机器级 calling convention，但前端必须先给出一致的 LLVM signature。

这叫 ABI classification：小 struct 可能拆进多个 registers，大 struct 可能通过 caller 提供的隐藏 sret pointer 返回。pplc 不应手工假设“所有 struct 都压栈”，而应构造正确 LLVM type 并让目标 ABI lowering 处理；与 C 互操作时还要确认两侧采用相同 calling convention 和 layout。

## extern 是一份不受编译器控制的合同

```pp
extern fn puts(s: *u8) -> int;
```

extern 只有声明没有 body。JIT 模式通过 `dlsym` 在当前进程的动态符号空间寻找同名函数，再把地址映射给 execution engine；build 模式则把 unresolved symbol 留给系统链接器和动态链接过程。

名字相同不代表 ABI 相同。参数宽度、pointer、struct 传值、返回方式、varargs promotion 都必须与 C 侧声明一致。

类型安全证明通常假设函数环境中的 signature 真实可信。extern 打破了这一封闭世界假设：pplc 只能检查 call 与 pp declaration 一致，不能证明动态符号实际实现也一致。因此 FFI declaration 是 trusted boundary，错误声明相当于向类型系统提供了错误公理。

## str 不能冒充 C string

pplang 的 `str` 在语义上是 `{address, len}` 的 slice value；当前地址模型在 LLVM 中用 64 位地址整数承载 address，与 64 位 length 组成二字段聚合。C 的 `char*` 只有地址，并依赖 NUL 结束。

因此 extern 不允许直接返回一个没有长度来源的 `str`。正确边界是：

- C 返回 `*u8`，pp 侧通过明确长度构造 view；
- 或 C glue 同时返回 pointer 和 length；
- pp 传 C string 时显式保证 NUL、生命周期和不含内嵌 NUL。

这正是语言语义与工程 ABI 不应混为一谈的例子。

## varargs

C varargs 不携带完整类型列表，并应用 default argument promotions。例如较小整数通常提升为 `int`。pplc 必须按 C ABI 规则准备额外参数，而不能仅按 pp 表面类型传递。

varargs 只适合作为 FFI 能力，不应成为 pplang 普通函数抽象的默认方式；显式 tuple、slice 或 generic container 有更强的静态合同。

## 函数指针是泛型 capability 的基础

`fn(T,T)->bool` 单态化后成为具体 LLVM function signature，取地址得到 opaque `ptr`，间接调用仍需要保存的函数类型来构造 call。这与 opaque pointer 的原则一致：pointer value 不携带 callable signature，前端环境必须携带。

自动取址的 method call 也在调用 lowering 前完成 receiver 适配。只有 addressable `T` 才能自动变为 `*T`，以免把临时值地址泄漏到超出生命周期的位置。

## unsafe 在哪里

pplang v0.3 没有装饰性的 `unsafe {}` 语法，但编译器实现与运行系统当然存在不安全边界：JIT 函数指针 cast、dlsym 地址、raw pointer load/store、volatile 和内联机器能力。它们应由 builtin/FFI 合同与测试约束，而不是用一个没有实际限制效果的语法块制造安全错觉。

## ABI 实验

选一个 `extern fn add(a:int,b:int)->int`，分别追踪 pp prototype、LLVM declaration、object undefined symbol 和 C implementation。随后故意把 C 侧一个参数改成 `double`：链接仍可能成功，但行为不再受保证。这个实验比单独背 calling convention 更能说明“symbol identity”与“type/ABI identity”是两件事。
