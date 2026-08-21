---
title: 第一个 pp 程序
description: 构建 pplc，运行程序，并第一次观察 LLVM IR。
sidebar:
  order: 1
---

pplang 源文件使用 `.pp` 扩展名，编译器项目名为 pplc，可执行命令名为 `pp`。这一章先完成最短反馈循环，再解释代码经过了什么。

## 准备环境

当前 pplc 使用 Rust、inkwell 和 LLVM 18。在仓库根目录构建：

```sh
cd pplc
cargo build
```

产物位于 `pplc/target/debug/pp`。运行教程示例：

```sh
./target/debug/pp run ../tutorial/examples/pplang/hello.pp
```

输出包含程序打印的文本和 `main` 的返回值：

```text
hello, pp
0
```

## 程序从 `main` 开始

```pp
fn main() -> int {
    println("hello, pp");
    return 0;
}
```

- `fn` 声明函数。
- `main` 是 hosted 程序入口。
- `-> int` 是返回类型契约。
- block 使用花括号，普通语句以分号结束。
- `println` 是基础输出 builtin。
- `return 0` 产生 `main` 的整数结果。

这几行已经体现静态语言的核心约定：调用前就能知道参数和返回类型，编译器不需要等程序运行后再决定 `main` 是什么。

## 一份源码，四条输出路径

```sh
./target/debug/pp ir ../tutorial/examples/pplang/hello.pp
./target/debug/pp run ../tutorial/examples/pplang/hello.pp
./target/debug/pp build ../tutorial/examples/pplang/hello.pp -o /tmp/hello
./target/debug/pp obj ../tutorial/examples/pplang/hello.pp -o /tmp/hello.o
```

| 命令 | 结果 | 适合观察什么 |
|---|---|---|
| `ir` | LLVM IR 文本 | 类型、调用与控制流如何降级 |
| `run` | JIT 执行 | 最快验证行为 |
| `build` | 宿主机可执行文件 | 完整编译和链接 |
| `obj` | 目标文件 | 与 C、静态库或其他链接步骤组合 |

`pp os` 生成 freestanding 裸机目标，等到系统边界章节再使用。

## 从源代码到执行

```text
hello.pp
  ↓ lexer
token
  ↓ parser
AST
  ↓ semantic analysis
有类型的程序
  ↓ LLVM codegen
IR
  ↓ JIT 或目标文件/链接
运行结果
```

龙书用“前端、优化、中间表示、后端”组织编译器知识。pplc 当前没有试图实现大型优化器，但保留了这条基本分层。PLAI 则提醒我们：理解一个语言最有效的方法之一，是观察每层如何给上一层语法赋予含义。

## 第一次读 IR

执行 `pp ir`，先不要试图读懂全部内容，只找三件事：

1. `main` 的 LLVM 返回类型是否对应 pp 的 `int`。
2. 字符串是否同时携带地址和长度信息。
3. `return 0` 最终是否成为函数的返回指令。

后续章节每引入一种类型或控制流，都会回到 IR 验证一次。教程学习的是 pplang，但机器表示始终是这门系统语言的一部分。

## 动手实验

1. 把返回值改为 `42`，再次执行 `pp run`。
2. 删除 `println`，比较新的 IR。
3. 把返回值改成字符串，观察编译器在什么阶段拒绝它。

第三项不是为了“修好”程序，而是开始区分语法正确和类型正确：parser 可以接受 `return` 后的表达式，sema 仍会检查它是否满足函数契约。

:::tip[完整示例]
本章代码位于 `tutorial/examples/pplang/hello.pp`，教程验证脚本会实际编译和运行它。
:::
