---
title: 函数、方法与 defer
description: 值参数、函数指针、方法糖和退出清理。
sidebar:
  order: 4
---

## 函数是显式契约

```pp
fn add(a: int, b: int) -> int {
    return a + b;
}

fn log_message(message: str) {
    println(message);
}
```

没有 `->` 的函数返回 `void`。参数按值传递；struct 传参得到值副本，修改原对象时传入指针。

## 函数指针

函数指针类型写成 `fn(T1,T2)->R`，函数地址写成 `&name`：

```pp
fn int_less(a: int, b: int) -> bool {
    return a < b;
}

let less: fn(int, int) -> bool = &int_less;
let ordered: bool = less(2, 3);
```

它不仅用于回调，也是 v0.3 泛型的能力约束机制。

## 方法只是调用糖

如果普通函数的第一个参数能接收某个值，`value.method(args)` 会改写为 `method(value,args)`。第一个参数是 `*T` 而接收者是可取址的 `T` 局部变量时，编译器自动取址。

```pp
fn move_by(point: *Point, dx: int, dy: int) {
    point.x = point.x + dx;
    point.y = point.y + dy;
}

point.move_by(4, 5);
```

这里没有类、方法表或动态分派。

## defer

`defer expression;` 在函数退出时执行，多个 defer 按后进先出顺序运行，包括通过提前 `return` 退出。

```pp
let values: Vec[int] = vec_new[int]();
defer values.vec_free[int]();
```

v0.3 的 defer 绑定到函数退出，不是任意 block 退出。它减少遗漏清理，不改变内存仍由程序显式管理的事实。
