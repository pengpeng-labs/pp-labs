---
title: 函数、调用与 defer
description: 从类型契约、调用栈走到回调、方法糖和资源清理。
sidebar:
  order: 4
---

函数把一段计算变成可命名、可检查的边界。参数和返回类型描述调用契约，调用约定决定它最终如何经过寄存器、栈和内存。

## 函数是显式契约

```pp
fn add(a: int, b: int) -> int {
    return a + b;
}

fn log_message(message: str) {
    println(message);
}
```

没有 `->` 的函数返回 `void`。编译器在调用前检查参数数量和类型，在函数体中检查每个 return。

参数按值传递。标量得到值，struct 等 aggregate 也遵循值语义；若函数需要修改调用者的对象，应显式接收指针。

## 调用栈只是 hosted 实现的一部分

CSAPP 会沿着调用指令、栈帧、寄存器和返回地址解释过程调用。pplang 的源码不直接规定具体寄存器分配，而是把函数类型与 aggregate 交给 LLVM 目标 ABI。

程序员仍然需要知道两件事：

1. 局部变量的地址在函数返回后不再有效。
2. extern 边界必须与对方的 ABI 完全一致。

高级函数契约和底层调用约定是同一件事的两个层面。

## 函数指针把行为变成值

```pp
fn int_less(a: int, b: int) -> bool {
    return a < b;
}

let less: fn(int, int) -> bool = &int_less;
let ordered: bool = less(2, 3);
```

`&int_less` 取得函数地址，函数指针类型记录参数和返回类型。pplang 没有闭包捕获；函数指针指向普通函数。

函数指针用于：

- 驱动和 shell 的回调表。
- 协程入口。
- 将比较、哈希或分配能力传给泛型算法。
- 为 C 胶水提供窄回调接口。

## 方法只是首参数调用糖

```pp
struct Point { x: int, y: int }

fn move_by(point: *Point, dx: int, dy: int) {
    point.x = point.x + dx;
    point.y = point.y + dy;
}

let point: Point = Point { x: 1, y: 2 };
point.move_by(4, 5);
```

最后一行等价于 `move_by(&point, 4, 5)`。编译器对可取址局部变量自动取址，但没有类、方法表或动态分派。

Go 展示了值接收者和指针接收者如何改善 API 阅读体验。pplang 借用这种调用体验，同时把实现保持为普通函数。

## defer 把清理绑定到退出

```pp
let values: Vec[int] = vec_new[int]();
defer values.vec_free[int]();
```

`defer expression;` 在函数退出时执行。多个 defer 按后进先出顺序运行，提前 return 也会触发。

```pp
defer println("third");
defer println("second");
defer println("first");
return 0;
```

输出顺序是 `first`、`second`、`third`。v0.3 defer 绑定函数退出，不绑定任意 block；它减少遗漏清理，但不会自动决定谁拥有内存。

## 动手实验

1. 为 `Point` 增加一个值接收者函数，比较值传递与指针接收者的结果。
2. 写两个签名不同的函数，尝试赋给同一个函数指针变量。
3. 在多个 return 路径前注册 defer，验证每条路径的执行顺序。
4. 在 ppdb 中查找 scanner 或比较函数，判断其状态更适合值、指针还是函数指针。

:::note[理论落点]
类型系统负责检查函数契约；CSAPP 解释调用如何落到机器；Go 提供方法调用的工程对照；pplang 用普通函数、函数指针和少量语法糖连接这三层。
:::
