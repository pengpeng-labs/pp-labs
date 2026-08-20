---
title: 控制流与作用域
description: if、while、for、break、continue 和词法 shadowing。
sidebar:
  order: 3
---

## 分支与循环

`if` 和 `while` 的条件必须是 bool，并保留括号：

```pp
if (value < 0) {
    return -1;
} else if (value == 0) {
    return 0;
} else {
    return 1;
}
```

计数或遍历优先使用 `for`：

```pp
let total: int = 0;
for value in range(5) {
    total = total + value;
}
```

`range(n)` 产生从 0 到 `n - 1` 的整数序列。`for x in array` 和 `for byte in text` 分别遍历数组元素与字符串字节。需要手动更新状态时才使用 `while`；`break` 和 `continue` 只能出现在循环中。

## 每个 block 都建立作用域

```pp
let value: int = 1;
if (true) {
    let value: int = 2;
    println("inner");
}
return value;
```

内层声明可以 shadow 外层同名变量；离开 block 后，外层绑定恢复。同一个作用域内重复声明同名变量是编译错误。

完整示例在 `tutorial/examples/pplang/control.pp`，运行结果是 `11`。
