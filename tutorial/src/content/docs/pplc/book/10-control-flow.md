---
title: 10. 控制流、短路与 Defer
description: 把 if、loop、break、switch 和退出清理翻译为 CFG。
---

控制流 lowering 的核心不是“调用 build_if”，而是构造 basic block 和它们之间的边。每个源语言结构都应先画出 CFG，再写 Builder 调用。

龙书把这种过程称为 syntax-directed translation：AST 构造决定生成哪些 labels、branches 和 temporaries。对 statement，可用两个属性理解：`entry(s)` 是进入 block，`next(s)` 是完成后控制流去向。

## if 的菱形

```text
             ┌────────┐
             │ entry  │
             └───┬────┘
                 │ condbr
          ┌──────┴──────┐
          ▼             ▼
       then           else
          └──────┬──────┘
                 ▼
               merge
```

pplc 先编译条件并确认得到 `i1`，创建 then/else/merge blocks，再为没有 terminator 的分支补到 merge 的无条件跳转。若分支已经 `return`，绝不能再追加第二个 terminator。

即使没有 `else`，false edge 也直接指向 merge。merge 可能暂时没有前驱，例如两个分支都 return；LLVM 允许存在不可达 block，但更成熟的 CFG cleanup 可稍后移除。

对应翻译规则的骨架是：

```text
lower(if c then s1 else s2, next):
  tc = lower_value(c)
  branch tc, Lthen, Lelse
Lthen: lower(s1, Lnext)
Lelse: lower(s2, Lnext)
Lnext:
```

`next` 属性避免每层自己猜结束点，也解释 Builder 为什么必须在每个 arm 生成后重新确认当前 block 是否已有 terminator。

## while 的回边

`while` 分成 condition、body 和 after：当前 block 先跳到 condition，condition 在 body/after 间选择，body 尾部回到 condition。`break` 跳到 after，`continue` 跳到 condition。

嵌套循环用 `loop_stack` 保存 `(continue_target, break_target)`。进入循环 push，离开 pop；于是最内层的 break/continue 自动命中最近循环。sema 应先拒绝循环外使用，codegen 再保留防御性检查。

## `&&` 与 `||` 必须短路

逻辑运算不是普通的 eager binary instruction。`false && rhs` 不应执行 rhs，`true || rhs` 也不应执行 rhs。正确 lowering 需要分支和 merge，结果可用 phi 或临时栈槽合并。

这个差别在 rhs 有函数调用、volatile IO 或除零时可观察。只用 LLVM `and i1`/`or i1` 会先求两侧值，改变源程序语义。

传统 backpatching 会暂存尚不知道目标地址的 true-list/false-list，等目标 label 建立后回填。Inkwell 允许先创建 BasicBlock handle 再发 branch，因此不需要文本级回填，但 true/false edges 的理论结构完全相同：

```text
lower_branch(a && b, T, F):
  lower_branch(a, Lrhs, F)
Lrhs:
  lower_branch(b, T, F)
```

这个规则直接证明 rhs 仅在 a 为 true 时可达。

## switch 是 tag dispatch

enum switch 先把值保存到临时地址，读取 tag，再用 LLVM `switch` 跳到每个 arm block。payload binding 从 payload 区按 variant 类型 load，并只加入当前 arm scope。

静态穷尽性已由 sema 保证，但 codegen 仍为无 wildcard 的非法 tag 路径生成 `llvm.trap` + `unreachable`。这是对内存破坏或 FFI 伪造值的防御，不是代替穷尽检查。

## defer 是退出路径重写

```pp
defer close(fd);
work(fd);
return 0;
```

语义要求在退出前按 LIFO 执行清理。pplc v0.3 把 defer expression 压入函数级 `defer_stack`，在显式 return 和默认 return 前逆序发射。

真正困难的不是 LIFO，而是“所有退出边”：多个 return、错误路径、未来可能的 early propagation 都必须执行相同清理；break/continue 是否离开 defer 所属 scope，也取决于语言定义。工业实现通常把 defer lowering 成显式 cleanup blocks，或在结构化 IR 层统一重写退出边。

当前实现适合 v0.3 的函数级 defer 模型。新增 block-scoped defer 或异常机制前，应先升级控制流表示，而不是在每个 statement 分支里继续补特殊情况。

从 CFG 角度，defer 是把每条离开作用域的 edge 改写为 `edge -> cleanup -> original target`。当 return、break、continue、trap 和未来异常同时存在时，先建立统一 exit-edge 模型比在 AST visitor 中零散调用 `emit_defers` 更容易证明覆盖完整。

## CFG 检查清单

- 每个已生成 block 恰好一个 terminator；
- return 后不再生成普通指令；
- loop stack 在错误返回时也恢复；
- 每条退出路径执行正确 defer；
- short-circuit rhs 只在需要时可达；
- merge 后 Builder 插入点位于正确 block。
