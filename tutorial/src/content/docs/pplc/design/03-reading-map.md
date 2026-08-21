---
title: 3. 理论与工程阅读地图
description: 八本教材中哪些思想直接进入了 pplc。
---

pplc 不是八本教材的摘要。它是一个交汇点：语言理论规定什么程序有意义，编译原理组织翻译过程，体系结构与系统知识约束最后生成的机器接口。

| 来源 | 理论单元 | pplc 的可观察落点 |
|---|---|---|
| 龙书 | 正规语言、DFA、maximal munch | `TokenKind`、`next_token`、共享前缀运算符 |
| 龙书 | CFG 文法、左递归、LL、语法制导翻译 | `parse_binary`、postfix、AST 到 basic block |
| 龙书 | symbol table、三地址代码、runtime environment | scope stack、LLVM temporaries、function lowering |
| TAPL | judgment、formation/introduction/elimination | `expr_type`、enum constructor、switch |
| TAPL | canonical forms、progress、preservation | bool condition、穷尽检查、赋值/return 类型保持 |
| TAPL | substitution、参数多态 | template validation、单态化与实例闭包 |
| PLAI | datatype 表示语言、环境与 store | Rust AST、name-to-alloca、load/store |
| PLAI | 逐步扩展与语义责任 | 每个 AST variant 对应 parser/sema/codegen/tests |
| 组成原理 | bit、补码、指令、对齐、endianness | signed/unsigned lowering、layout、packet bytes |
| CSAPP | activation record、ABI、object、linking | call、extern、symbols、relocations、`cc` |
| OSTEP | process/runtime abstraction | JIT 宿主与 freestanding ppos 环境的差别 |
| 数据库教材 | page/index/transaction invariant | ppdb 作为布局、泛型、FFI、持久化 workload |
| 网络教材 | message format、分层、健壮解析 | packet parser 的 length、byte order、bounds |

前三类直接塑造语言和编译算法；组成原理、CSAPP 与 OSTEP 解释 IR 最终为何必须服从机器和运行环境；数据库与网络教材提供“不能只编译玩具表达式”的压力测试。后两类不是 lexer/parser 理论，不会被生硬塞进每章。

## 怎样穿插阅读

读 lexer/parser 时，先画状态机或写 grammar，再对照 Rust 控制流；读类型检查时，先写 judgment 与 inference rule，再对照 sema 分支；读 LLVM 后端时，先画三地址表示、CFG、layout 或 object/linking model，再读 Inkwell API。

每一章都采用同一顺序：工程问题、教材模型、pp 规则推导、pplc 实现映射、设计取舍、反例实验。理论负责解释“为什么必须这样”，代码负责展示“怎样把它做成”，测试负责观察两者是否一致。
