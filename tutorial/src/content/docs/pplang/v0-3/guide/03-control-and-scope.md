---
title: 控制流、状态与作用域
description: 用明确分支组织状态变化，用词法环境约束名字。
sidebar:
  order: 3
---

控制流决定下一步执行哪条语句，作用域决定当前位置的名字指向哪个绑定。这两个问题在小示例中容易被忽略，在 parser、数据库扫描器和操作系统循环中却无处不在。

## 分支必须得到 bool

```pp
fn classify(value: int) -> int {
    if (value < 0) {
        return -1;
    } else if (value == 0) {
        return 0;
    } else {
        return 1;
    }
}
```

比较表达式产生 bool，`if` 根据它选择 block。这里没有 C 式隐式真值；`if (value)` 是类型错误。

从 PLAI 的求值视角看，程序状态会在语句之间推进；条件表达式决定采用哪条状态转换路径。严格 bool 让“选择路径”和“普通数值”成为不同类别。

## 三种循环

已知遍历对象时优先使用 `for`：

```pp
let total: int = 0;
for value in range(5) {
    total = total + value;
}
```

`range(n)` 产生 `0` 到 `n - 1`。数组和 str 也可以遍历：

```pp
let values: [3]int = [2, 4, 6];
for value in values {
    total = total + value;
}

for byte in "pp" {
    total = total + byte;
}
```

状态决定是否继续时使用 `while`：

```pp
while (remaining > 0) {
    remaining = remaining - 1;
}
```

`break` 退出最近循环，`continue` 开始下一轮。两者不能出现在循环外。

## block 是名字环境

```pp
let value: int = 1;
if (true) {
    let value: int = 2;
    println("inner");
}
return value;
```

函数体和每个 block 都建立词法作用域。名字查找从内向外进行：

```text
函数作用域 value = 1
  └─ if block value = 2
       └─ 这里的 value 指向 2
离开 block 后，value 再次指向 1
```

这就是 shadowing。它创建新绑定，不是临时修改外层变量。同一作用域重复声明同名变量会报错。

TAPL 常用环境 `Γ` 记录名字到类型的映射。pplc 的 sema 使用作用域栈实现同一个思想：进入 block 压入一层，离开时弹出，查找从栈顶向外进行。

## 工程中的作用域

- ppdb 的 `DbScan` 把扫描位置放进独立 struct，两个嵌套扫描器不会共享隐藏全局状态。
- switch payload 只在对应 arm 的 block 内可见，离开分支后不能误用。
- ppos 中临时解析变量可以 shadow 外层名字，但设备状态等长期变量应避免含糊覆盖。

作用域不仅避免命名冲突，也限制状态能被观察和修改的范围。

## 动手实验

1. 运行 `tutorial/examples/pplang/control.pp`，手算每个 block 中名字的值。
2. 在同一 block 再声明一次 `value`，记录诊断。
3. 把一个 `if` 中声明的变量移到 block 外使用，解释为什么它不在环境中。
4. 用 `pp ir` 观察 `if` 和 `while` 生成的基本块与跳转。

:::note[理论落点]
PLAI 帮助我们把控制流看成状态变化；TAPL 的类型环境解释词法作用域。pplang 将二者落实为严格条件和真正的 block scope。
:::
