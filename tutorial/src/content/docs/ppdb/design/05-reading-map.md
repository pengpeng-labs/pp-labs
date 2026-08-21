---
title: 5. 理论与项目参考地图
description: 数据库主教材、系统教材和参考实现怎样进入 ppdb。
---

ppdb 的第一理论来源是 Silberschatz、Korth、Sudarshan 的 *Database System Concepts*。其他教材解释 compiler、机器、OS 和网络边界；参考项目提供可比较的工程结构。它们不会被平均塞进每章。

## 八本教材

| 来源 | 理论单元 | ppdb 落点 |
|---|---|---|
| Database System Concepts | relation/schema/tuple | catalog、column、record |
| Database System Concepts | file/record organization | heap page、slot array、scan |
| Database System Concepts | index/query processing | `(key,rowid)`、cursor、planner |
| Database System Concepts | transaction/recovery | before-image、ACID 边界、PDB4 |
| 龙书 | lexer、grammar、AST/IR | SQL front end、typed statement |
| PLAI | datatype、environment、state | `DbStmtKind`/`DbValue`、cursor state |
| TAPL | sum type 与穷尽消去 | parser/executor 的 enum/switch |
| Computer Organization and Design | width、alignment、endianness | page bytes、record layout、PDB4 |
| CSAPP | memory、binary representation、file/ABI | raw record、serialization、native FFI |
| OSTEP | filesystem、persistence、crash consistency | file provider、durability 边界 |
| Kurose & Ross | layering、application protocol | MCP/JSON-RPC 是外层工具协议 |

数据库和系统教材解决不同问题：关系代数不能告诉我们 POSIX short read 怎样处理，CSAPP 也不能定义 SELECT 的逻辑结果。教程在问题所属层引用理论。

## 参考项目

| 项目/课程 | 借鉴 | 没有复制 |
|---|---|---|
| MIT SimpleDB | heap file、slotted page、iterator 教学结构 | Java runtime 与完整课程框架 |
| CMU BusTub | executor/access path/planner 分层 | C++ template、buffer pool/concurrency 全规模 |
| SQLite | embedded/single-file 产品形态、明确 SQL 边界 | B-tree、journal、VDBE、完整 SQL |
| LevelDB/RocksDB | get/put/delete API 与 ordered key 思维 | LSM、SSTable、compaction |
| MongoDB/document model | 完整 JSON document 的数据形态 | document query/index/distribution |
| LMDB | 嵌入式、多视图思路 | mmap/COW page architecture |

首版 relation index 使用有序数组而不是照搬 B+ tree；KV 使用有序数组而不是 LSM；Doc 保存 bytes 而不是模拟 MongoDB query。参考的目标是校准 abstraction 和 tradeoff，不是收集技术名词。

## 阅读方法

读每章时先找三个对象：教材定义的 abstract model、ppdb 声明的 invariant、代码中保存该 invariant 的数据结构。例如：

```text
教材：secondary index maps search key to record identifier
ppdb：ordered (key,rowid)
代码：db_idx_keys + db_idx_rowids
验证：ordering + live row + key equality
```

如果只能找到项目名称、找不到 invariant 和验证方式，说明理论还没有真正进入实现。
