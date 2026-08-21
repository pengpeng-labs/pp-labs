---
title: 0. 先建立一台数据库系统
description: 区分数据模型、查询处理、存储、事务与运行宿主。
---

数据库不等于“把结构体写进文件”。一台 DBMS 至少同时维护四种合同：用户看到的 logical model、查询的执行语义、数据的 physical representation，以及状态变化的 transaction/persistence 边界。

```text
external interface   SQL / KV / Doc / MCP
        │
logical model        schema, relation, key, document
        │
query processing     parse, resolve, scan, filter, project, plan
        │
storage              catalog, page, slot, record, index
        │
state management     transaction, image, host file provider
```

《Database System Concepts》中的三层 schema 架构帮助区分：external view 是特定用户/接口看到的数据；conceptual schema 描述 relation 与约束；internal schema 描述 page、record 和 index。ppdb 规模很小，但仍保留这条边界。

## 一条查询穿过哪些层

```sql
SELECT city FROM people WHERE id >= 7;
```

1. SQL parser 生成 statement，保存 table、projection、predicate；
2. catalog 把 `people`、`city`、`id` 解析成 table/column id 与类型；
3. planner 判断是否存在可用的单列 INT index；
4. cursor 从 seq scan 或 index scan 产生 row；
5. filter 验证 predicate；
6. project 读取 city column 并输出。

任何一层都不能偷用另一层的表示。SQL parser 不应知道 page offset；record scanner 不应比较列名字符串；MCP 不应绕过 parser 直接写 global arrays。

## 数据库 invariant

数据库代码的核心不是 CRUD 函数数量，而是 invariant。例如：

- 每个已分配 page 属于一个合法 table；
- slot 区与 record 区不能重叠；
- live row ID 唯一且能定位当前 record；
- catalog 中列数和类型决定固定 record size；
- index entry 指向存在且 key 相符的 row；
- load 成功后，整个状态满足以上条件；失败时旧状态不变。

后续每章都会先写 invariant，再看 pplang 实现。这样 corruption test 和 transaction rollback 才有明确目标。

## persistence 不等于 durability

`db save` 能让另一个进程 `db load`，说明状态可持久化。完整 durability 还要求 committed transaction 在 crash/power loss 后按承诺存在，通常涉及 WAL、fsync、write ordering 与 recovery。ppdb 没有这些机制，因此课程严格区分：

```text
serialization/persistence: 已实现
crash-safe durability:      未承诺
```

## 第一个实验

运行 `bash ppdb/tests/run_tests.sh`，不要只看“通过”。把测试按 logical、query、storage、transaction、persistence、host 六层分类。无法分类的 case 往往说明测试目标或架构责任还不清楚。
