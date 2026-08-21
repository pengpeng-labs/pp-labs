---
title: 参考资料：八本书与 pplang
description: 哪些章节直接塑造语言，哪些通过真实项目反向影响设计。
sidebar:
  order: 6
---

pp-labs 的四个项目来自一条系统学习路径，但八本书对 pplang 的影响并不相同。为了避免牵强归因，本页把它们分成三类：语言理论、编译与机器基础、验证工作负载。

```text
语言理论                编译与机器基础             真实工作负载
TAPL / PLAI             龙书 / COD / CSAPP         DB Concepts / OSTEP / Kurose
     \                         |                         /
      \                        |                        /
                 pplang 的设计与停止线
```

## 一、直接语言理论

### Types and Programming Languages

Benjamin C. Pierce，MIT Press。简称 TAPL。

重点对应：

| TAPL 章节 | 核心知识 | pplang 落点 |
|---|---|---|
| Ch. 1 Types in Computer Science | 类型系统的用途、类型与语言设计 | 静态拒绝无意义程序，而非只给变量贴标签 |
| Ch. 3–4 Arithmetic Expressions | 语法、求值、实现 | 区分 AST、动态语义和实现 |
| Ch. 8 Typed Arithmetic Expressions | typing relation；progress + preservation | 严格 bool、运算类型与类型安全直觉 |
| Ch. 9–10 Simply Typed Lambda-Calculus | 函数类型、环境、typechecking | 函数签名、调用、返回与 sema |
| Ch. 11 Simple Extensions | pairs、tuples、records、sums、variants | tuple、struct、enum、payload 与 switch |
| Ch. 13 References | store、引用与类型安全 | 指针和可变状态的理论对照；pp 选择更低层裸指针 |
| Ch. 22 Type Reconstruction | constraints、unification、implicit annotations | 帮助理解推断成本；v0.3 有意不做泛型实参推断 |
| Ch. 23 Universal Types | parametric polymorphism、System F | 显式泛型的理论背景，但实现采用单态化 |

pplang 没有实现 TAPL 的完整演算、subtyping、existential types 或高阶 polymorphism。TAPL 提供的是判断语言，不是功能采购表。

最重要的两个落点是：

1. struct 与 tuple 是积类型，enum 是和类型。
2. “类型安全”需要说明哪些 stuck state 被排除，而不是只说“强类型”。

参考：[TAPL 官方目录](https://www.cis.upenn.edu/~bcpierce/tapl/contents.pdf)。

### Programming Languages: Application and Interpretation

Shriram Krishnamurthi，PLAI 3rd Edition。

重点对应：

| PLAI 部分 | 核心知识 | pplang 教程落点 |
|---|---|---|
| Learning SMoL / Evaluation | 用小语言和求值器理解语义 | 先建立语言模型，手工追踪状态变化 |
| Representing Arithmetic | 程序表示、abstract syntax、evaluator | token 与源码不是 AST；实现帮助理解语义 |
| Parsing: From Source to ASTs | parser 连接表面语法和抽象结构 | pplang EBNF 与 pplc AST 的职责 |
| Evaluating Conditionals | truthy/falsy 的设计空间、bool value | 为什么 pplang 拒绝整数条件 |
| Evaluating Local Binding | binding、static scoping、environment | block scope、shadowing 与作用域栈 |
| Evaluating Functions | 函数表示、环境与调用 | 函数类型、调用契约和函数指针 |
| Syntactic Sugar | core language、desugaring、name capture | 方法、for、tuple 解构和 defer 的语义解释 |
| Types / Judgments and Errors | typing judgment、assume-guarantee | 把 sema 诊断理解为规则前提失败 |
| Safety and Soundness | 类型安全与显式内存的张力 | 明确类型安全不等于裸指针内存安全 |
| Algebraic Datatypes | variant、pattern matching、space | enum、payload、穷尽 switch |

PLAI 对本教程方法的影响比对具体语法更大：不仅实现，还要从 evaluation、implementation、experimentation 和 real-world analysis 多个视角学习语言。

参考：[PLAI 官方站与当前版本](https://www.plai.org/)。

## 二、编译与机器基础

### Compilers: Principles, Techniques, and Tools

Alfred V. Aho、Monica S. Lam、Ravi Sethi、Jeffrey D. Ullman，通常称“龙书”。

| 龙书章节 | 对 pplang/pplc 的影响 |
|---|---|
| Ch. 1 Compiler Structure | lexer → parser → semantic analysis → IR → codegen 的总流水线 |
| Ch. 2 Syntax-Directed Translator | 让一门教学语言可以边解析边建立明确结构 |
| Ch. 3 Lexical Analysis | token、关键字、字面量与词法错误边界 |
| Ch. 4 Syntax Analysis | EBNF、递归下降、表达式优先级和结合性 |
| Ch. 5 Syntax-Directed Translation | AST 节点怎样携带后续阶段所需信息 |
| Ch. 6 Intermediate-Code Generation | 类型检查、控制流、switch 与过程 IR |
| Ch. 7 Run-Time Environments | 栈、堆、局部绑定和存储组织 |
| Ch. 8 Code Generation | 地址、基本块、目标语言和指令选择 |

它主要塑造 pplc，但也反向约束 pplang：语法必须能被清楚解析，语义必须在 AST 与类型阶段表达，系统能力必须能降到 LLVM 或窄 builtin。

pplang 没有为了覆盖龙书全部内容而加入 GC、闭包、复杂优化或 parser generator。参考：[Pearson 的龙书目录](https://www.pearson.com/en-us/subject-catalog/p/Aho-Compilers-Principles-Techniques-and-Tools-2nd-Edition/P200000003472?view=educator)。

### Computer Organization and Design

David A. Patterson、John L. Hennessy，副标题 *The Hardware/Software Interface*。

各版本会采用不同 ISA，但稳定主线是：

| 主题 | pplang 落点 |
|---|---|
| Computer Abstractions and Technology | 语言层、编译器层与机器层必须分层解释 |
| Instructions: Language of the Computer | 算术、比较、分支和调用最终成为目标指令 |
| Arithmetic for Computers | 位宽、补码、有符号/无符号运算与转换 |
| The Processor | 控制流、调用和 builtin 最终进入处理器执行 |
| Memory Hierarchy | 连续布局、局部性、页、Buf/Vec 的工程代价 |
| I/O and Interrupts（版本位置不同） | volatile、MMIO、端口 IO 与中断 builtin |

这本书解释“为什么系统语言必须关心表示与目标”，但不决定 pplang 应该采用哪套高级类型。

### Computer Systems: A Programmer’s Perspective

Randal E. Bryant、David R. O’Hallaron，简称 CSAPP。pplang 主要参考 3rd Edition 的程序员视角。

| CSAPP 章节 | pplang 落点 |
|---|---|
| Ch. 2 Representing and Manipulating Information | `int/u8...u64`、截断、位运算、地址通道 |
| Ch. 3 Machine-Level Representation | 函数、栈、控制流、指针与 aggregate 调用 |
| Ch. 6 Memory Hierarchy | 数组、页、缓冲和容器的局部性 |
| Ch. 7 Linking | `extern`、目标文件、静态库和 C 胶水 |
| Ch. 8 Exceptional Control Flow | ppos 中断、trap 与协程上下文；语言保持显式控制流 |
| Ch. 9 Virtual Memory | 地址有效性、allocator 与宿主差异 |
| Ch. 10 System-Level I/O | 字节缓冲、长度、文件接口与错误返回 |
| Ch. 11 Network Programming | `str`/Buf、FFI 和 socket 式边界 |
| Ch. 12 Concurrent Programming | atomic builtin、函数指针和共享状态边界 |

CSAPP 的直接影响是把类型一路追到运行中的机器，而不是让“系统编程”停留在裸指针语法。参考：[CSAPP 官方站](https://csapp.cs.cmu.edu/)。

## 三、通过项目施加压力的教材

### Database System Concepts

Abraham Silberschatz、Henry F. Korth、S. Sudarshan，7th Edition。

| 章节 | ppdb 工作负载 | 对 pplang 的反向影响 |
|---|---|---|
| Ch. 2–4 Relational Model and SQL | schema、SQL statement、value、transaction command | struct、enum、str、parser 数据结构 |
| Ch. 8 Complex Data Types | Doc 与文本数据 | 多模型值与字节视图 |
| Ch. 12–13 Physical Storage / Data Storage Structures | 页、记录、slot、buffer | 定长数组、裸指针、显式布局 |
| Ch. 14 Indexing | `(key,rowid)`、有序结构、二分 | tuple/struct、泛型复用、函数能力 |
| Ch. 15–16 Query Processing / Optimization | scan、filter、project、plan | 函数分层、scanner 状态与 Sum Type IR |
| Ch. 17–19 Transactions / Concurrency / Recovery | before-image、atomicity、load validation | 显式状态、复制、错误路径和 defer |

这些章节没有直接规定 pplang 语法；ppdb 作为真实消费者证明哪些语言机制缺失或不可靠。参考：[Database System Concepts 官方站](https://www.db-book.com/)。

### Operating Systems: Three Easy Pieces

Remzi H. Arpaci-Dusseau、Andrea C. Arpaci-Dusseau，简称 OSTEP。

OSTEP 以 virtualization、concurrency、persistence 三条主线组织操作系统：

| OSTEP 主线 | ppos 工作负载 | 对 pplang 的反向影响 |
|---|---|---|
| Virtualization / Process and Memory APIs | 栈、上下文、allocator、地址空间 | 裸指针、函数指针、地址转换、显式分配 |
| Concurrency / Threads and Locks | 协程、spinlock、共享状态 | `&func`、atomic_xchg、严格状态边界 |
| Persistence / Devices and File Systems | 内存 FS、二进制写入、ppdb 镜像 | byte buffer、数组、str 长度、错误结果 |

ppos 是单地址空间 unikernel，并没有实现 OSTEP 的完整进程与虚拟内存模型。正因为做了删减，教程必须明确哪些概念被采用、哪些没有实现。参考：[OSTEP 官方免费版本](https://pages.cs.wisc.edu/~remzi/OSTEP/)。

### Computer Networking: A Top-Down Approach

James F. Kurose、Keith W. Ross。不同版次章节会更新，本项目主要使用稳定的 Internet 五层主线。

| 章节 | ppos 网络工作负载 | 对 pplang 的反向影响 |
|---|---|---|
| Ch. 1 Layers and Service Models | 分层 API 与协议边界 | 模块职责、窄接口、胶水模式 |
| Ch. 2 Application Layer | HTTP、DNS、socket 编程 | str、Buf、JSON、FFI、错误路径 |
| Ch. 3 Transport Layer | UDP、TCP 状态和重传 | enum 状态、计时、函数分层 |
| Ch. 4 Network Layer Data Plane | IPv4 header、地址与校验和 | u8/u16/u32、数组、显式字节处理 |
| Ch. 6 Link Layer | Ethernet、ARP、frame、CRC/checksum | packet slice、volatile ring、边界检查 |

网络协议把“字符串”迅速变成“任意字节区间”，直接推动 pplang 从 NUL 指针收敛到带长度 str，并推动 Buf 成为标准库基础容器。参考：[Kurose & Ross 官方课程资源](https://gaia.cs.umass.edu/kurose_ross/online_lectures.htm)。

## 怎样使用这份书目

不要按八本书从头读完再开始 pplang。更有效的方式是：

1. 先读 pplang 对应章节并运行实验。
2. 根据每章“理论落点”回到相关教材章节。
3. 再到 pplc、ppdb 或 ppos 找真实实现。
4. 记录 pplang 采用了什么、删掉了什么、为什么。

这套教程的目标不是替代八本教材，而是提供一条贯穿路径：理论概念在语言中获得形式，在编译器中获得实现，在数据库、操作系统和网络中接受验证。
