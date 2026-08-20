---
title: Sum Type 与穷尽 switch
description: 用 enum 表达互斥状态，并让编译器检查所有分支。
sidebar:
  order: 8
---

struct 表达“同时拥有这些字段”，enum 表达“只能是这些情况之一”。

```pp
enum Result {
    Ok(int),
    Error(str),
}
```

每个变体最多携带一个 payload。无 payload 变体声明为 `None`，构造时写 `Option.None()`。

## 构造与拆解

```pp
fn divide(a: int, b: int) -> Result {
    if (b == 0) { return Result.Error("division by zero"); }
    return Result.Ok(a / b);
}

switch divide(84, 2) {
    Result.Ok(value) { return value; }
    Result.Error(message) {
        println(message);
        return 1;
    }
}
```

没有 `_` 时必须覆盖所有变体。不能重复匹配同一变体；`_` 最多出现一次且必须放在最后。payload 只支持一个名字的单层绑定，复杂数据先装进 struct。

## 为什么不用错误码

错误码把状态和值拆成两个容易失配的通道。`Result.Ok(int)` 保证 Ok 分支才有整数，`Result.Error(str)` 保证错误分支才有消息；switch 的穷尽检查则保证新增变体后旧调用点不能静默遗漏。

内部布局是稳定 `i32` tag 加足以容纳最大 payload 的存储，switch 降为对 tag 的 LLVM switch，不需要 GC 或运行时对象。

完整示例位于 `tutorial/examples/pplang/sum_type.pp`。
