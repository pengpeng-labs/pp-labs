---
title: 4. 参考资料与阅读方法
description: pplc 使用的编译原理、类型理论、系统与 LLVM 一手资料。
---

本页不是“延伸链接”堆砌，而是 pplc 设计论证的来源清单。阅读时应不断回到一个问题：书中的抽象，在当前编译器哪个数据结构、判断或 ABI 决策中出现？

## 编译原理主线

Alfred V. Aho、Monica S. Lam、Ravi Sethi、Jeffrey D. Ullman，*Compilers: Principles, Techniques, and Tools, 2nd Edition*。通常称为“龙书”。词法分析、语法分析、类型检查、中间代码生成、运行时环境与目标代码构成 pplc 的主干。pplc 选择手写 scanner 和递归下降 parser，但最长匹配、文法层次、符号表与 IR 的理论坐标来自这里。[Pearson 书目页](https://www.pearson.com/en-us/subject-catalog/p/Aho-Compilers-Principles-Techniques-and-Tools-2nd-Edition/P200000003472)

Shriram Krishnamurthi，*Programming Languages: Application and Interpretation*。PLAI 的价值是方法：用数据定义表达语言，再逐步加入 binding、state、functions 和 types，并让每次扩展都迫使实现者说明语义。建议把 AST/parser 章节和 PLAI 的表示演进方式对照阅读。[PLAI 官方站点](https://www.plai.org/)

## 类型系统

Benjamin C. Pierce，*Types and Programming Languages*。环境判断 `Γ ⊢ e : T`、积类型、和类型、canonical forms、progress/preservation 为 sema 提供概念工具。pplc 没有形式化证明整个语言，但 bool condition、variant payload 与穷尽检查都应能写成明确判断，而不是散落的后端猜测。[TAPL 目录](https://www.cis.upenn.edu/~bcpierce/tapl/contents.pdf)

## LLVM 一手资料

[My First Language Frontend with LLVM](https://llvm.org/docs/tutorial/MyFirstLanguageFrontend/) 适合建立 Context、Module、Builder、function、basic block、JIT 和 object emission 的最短闭环。pplc 与 Kaleidoscope 的差别同样重要：pp 有语句、内存、聚合类型、FFI、sum type 与显式泛型，不能停留在 expression-only language。

[LLVM Language Reference Manual](https://llvm.org/docs/LangRef.html) 是 IR 语义的权威来源。遇到 `getelementptr`、`icmp`、`switch`、`phi`、`load/store`、atomic 或 calling convention，优先查 LangRef，不依赖博客转述。

[Opaque Pointers](https://llvm.org/docs/OpaquePointers.html) 解释 LLVM 为什么不再让 pointer type 携带 pointee type，以及 load/GEP 等操作如何显式提供类型。这直接解释了 pplc 为什么必须在 LLVM pointer value 之外保留 pplang 的 `*T` 信息。

[LLVM Programmer's Manual](https://llvm.org/docs/ProgrammersManual.html) 用于理解 LLVM IR 对象模型、遍历、所有权与常用 API；具体 Rust 调用还需对照 Inkwell 0.10 和 LLVM 18 的绑定接口。

## 机器与系统边界

David A. Patterson、John L. Hennessy，*Computer Organization and Design*。整数宽度、补码、指令、对齐、存储层次和 ISA 帮助解释为什么一个 `u32` 类型决定 `udiv`/`icmp ult`，为什么 layout 是目标相关事实。

Randal E. Bryant、David R. O'Hallaron，*Computer Systems: A Programmer's Perspective*。机器级程序表示、链接、异常控制流、虚拟内存与系统级 IO 对应 pplc 的 object、symbol、relocation、ABI、地址与 extern 边界。[CSAPP 官方站点](https://csapp.cs.cmu.edu/)

Remzi H. Arpaci-Dusseau、Andrea C. Arpaci-Dusseau，*Operating Systems: Three Easy Pieces*。虚拟化、并发与持久化帮助区分“编译出机器码”和“拥有可运行环境”。`pp os` 没有 libc 和进程启动合同，正需要 ppos 提供 freestanding 宿主。[OSTEP 官方站点](https://pages.cs.wisc.edu/~remzi/OSTEP/)

## 真实工作负载

Abraham Silberschatz、Henry F. Korth、S. Sudarshan，*Database System Concepts*。关系模型、存储、索引、事务在 ppdb 中形成真实的大型 pp 程序，用来检验 aggregate、container、string、FFI 和持久化路径。[Database System Concepts 官方站点](https://www.db-book.com/)

James F. Kurose、Keith W. Ross，*Computer Networking: A Top-Down Approach*。协议分层、报文格式、可靠性与安全边界为 packet parser 和 ppos 网络栈提供工作负载，迫使 compiler 正确处理 byte、字节序、bounds 与状态机。[作者课程资料](https://gaia.cs.umass.edu/kurose_ross/online_lectures.htm)

## 推荐顺序

第一次学习按 pplc Book 顺序走，并把 LLVM tutorial 当实验手册。遇到类型规则回看 TAPL，遇到 AST 设计回看 PLAI，遇到 parsing/IR 分层回看龙书；到 ABI、object 与 freestanding 再进入 CSAPP、组成原理和 OSTEP。数据库与网络不是前置理论，而是检验编译器能否离开玩具示例的工程压力。
