---
title: pplc 编译器教程
description: 从 pp 源码、类型判断与泛型单态化走到 LLVM IR、JIT 和目标文件。
---

# 把一门语言变成程序

pplc 是 pplang 的编译器，也是一次完整的编译原理工程实践。它用 Rust 描述 token、AST 和编译阶段，通过 Inkwell 构造 LLVM IR，最后支持解释式体验、主机程序和 freestanding 目标：

```text
.pp source
    │
    ▼
lexer ──> parser ──> import expansion
                         │
                         ▼
                 monomorphization
                         │
                         ▼
                  semantic analysis
                         │
                         ▼
                    LLVM codegen
                    /     |      \
                  IR     JIT    object
                                /    \
                              cc   freestanding
```

这不是一份只教“怎样调用 LLVM API”的手册。课程关注三个同时成立的问题：

- 龙书中的 lexer、parser、symbol table 和 intermediate representation，怎样变成一个可维护的 Rust 工程；
- TAPL 的类型判断、progress/preservation 思想，怎样变成会拒绝错误程序的语义检查；
- CSAPP 与计算机组成中的 ABI、内存布局、指令有符号性和链接，怎样决定生成 IR 的正确性。

## 学习路线

先读[为什么是 Rust + LLVM](./design/02-rust-and-llvm/)，了解工具选择与边界。随后按 `pplc Book` 顺序完成：

1. 建立编译流水线和 LLVM IR 的整体模型；
2. 实现 token、AST、递归下降 parser 与 import 展开；
3. 建立作用域、类型判断、和类型穷尽检查；
4. 理解 Ada 式显式泛型如何通过单态化落地；
5. 把值、内存、控制流、聚合类型和 FFI 降到 LLVM IR；
6. 走通 JIT、目标文件、系统链接与 freestanding 发射；
7. 用 packet parser 做一次端到端编译追踪。

## 你需要什么

- 已读过 [pplang v0.3](../pplang/v0-3/) 的值、控制流、和类型与泛型章节；
- 能阅读基础 Rust，尤其是 `enum`、`match`、`Result`、`HashMap` 与借用；
- 本机安装 LLVM 18。仓库的 `pplc/.cargo/config.toml` 已配置 Homebrew 路径。

```bash
cd pplc
cargo test
cargo build
./target/debug/pp ir ../examples/fib.pp
./target/debug/pp run ../examples/fib.pp
```

## 课程边界

pplc v0.3 是一个直接、可读的小型编译器，不假装自己已经是工业优化编译器：当前没有独立 HIR/MIR，没有优化 pass 管线，也没有增量编译。它选择“单态化 AST 直接生成 LLVM IR”，让每个语言语义都能追到一段明确的 Rust 和 IR。课程会讲清这个选择带来的收益，也会指出何时需要演进。

实现的快速索引见[源码与阶段地图](./reference/source-map/)。
