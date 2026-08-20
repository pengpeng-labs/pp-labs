---
title: 第一个 pp 程序
description: 构建 pplc，并运行 Hello World。
sidebar:
  order: 1
---

pp 源文件使用 `.pp` 扩展名，编译器可执行文件名为 `pp`。当前编译器依赖 Rust、Cargo 和 LLVM 18。

## 构建编译器

在仓库根目录执行：

```sh
cd pplc
cargo build
```

编译器位于 `pplc/target/debug/pp`。先运行教程中的完整示例：

```sh
cd pplc
./target/debug/pp run ../tutorial/examples/pplang/hello.pp
```

输出包含程序打印的文本和 `main` 的返回值：

```text
hello, pp
0
```

## 程序入口

```pp
fn main() -> int {
    println("hello, pp");
    return 0;
}
```

`fn` 声明函数，`-> int` 声明返回类型。语句以分号结束，block 使用花括号。`println` 是编译器识别的基础输出能力，`main` 的整数返回值由 `pp run` 打印。

## 看见编译结果

同一源文件可以进入不同路径：

```sh
./target/debug/pp ir ../tutorial/examples/pplang/hello.pp
./target/debug/pp build ../tutorial/examples/pplang/hello.pp -o /tmp/hello
./target/debug/pp obj ../tutorial/examples/pplang/hello.pp -o /tmp/hello.o
```

- `ir` 输出 LLVM IR，适合学习和诊断。
- `run` 使用 JIT 执行。
- `build` 链接为宿主机可执行文件。
- `obj` 只生成目标文件，交给外部链接步骤。
- `os` 面向 freestanding 构建，在系统边界章节再讨论。

:::tip[完整示例]
本章代码位于 `tutorial/examples/pplang/hello.pp`，教程 CI 会实际编译它。
:::
