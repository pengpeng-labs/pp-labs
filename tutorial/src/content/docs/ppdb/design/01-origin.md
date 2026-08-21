---
title: 1. 为什么亲手写一个数据库
description: 从数据库课程的抽象回到可以运行的页、查询与事务。
---

《Database System Concepts》把数据库拆成多个互相约束的层次：关系模型定义数据的逻辑含义，查询处理把声明式请求变成执行计划，存储管理把 tuple 放进 page，事务与恢复管理状态变化。读懂这些层次不等于已经理解它们怎样在一段系统代码中相遇。

ppdb 的第一个目标就是把这条链闭合：

```text
CREATE TABLE / INSERT / SELECT
              │
              ▼
       parsed statement
              │
              ▼
       scan/filter/project
              │
              ▼
        heap page + slots
              │
              ▼
          PDB4 image
```

一条 SELECT 最终必须回答非常具体的问题：表名在哪里解析，列名怎样映射到 offset，record 在哪个 page/slot，删除后索引怎样找到它，load 失败会不会留下半个 catalog。这些问题正是“数据库原理”变成“数据库系统”的地方。

## 为什么用 pplang

ppdb 同时验证 pplang 是否能承担真实系统负载：struct/array 表达 page 与 catalog，pointer 与整数地址操作 record，sum type 表达 SQL statement/value，词法作用域和泛型容器支撑模块化代码，FFI 连接 native file API。

如果编译器只会运行 fibonacci，很难暴露 layout、unsigned comparison、slice length、FFI ABI 或 whole-program 单态化问题。数据库的持久状态会放大错误：一个错误 offset 可能在数十次操作后才表现为损坏镜像。

因此 ppdb 不只是 pplang 的示例，也反过来成为语言和编译器的语义压力测试。

## 为什么保持小型

ppdb 选择 512B page、固定表数和固定容量 model，不追求 benchmark。小型边界带来三项教学价值：

- 页面每个 byte 都能画出来，空间上限可以手算；
- full、corruption、rollback 等失败状态可以穷举测试；
- 同一 core 能进入没有进程、mmap 和成熟 filesystem 的 ppos。

如果直接采用 buffer pool、B+ tree、MVCC、WAL 和 cost-based optimizer，课程会迅速变成框架导航，反而看不见最基本的 invariant。

## 后来的 Agent 线

Agent 兴起后，ppdb 获得第二个具体场景：messages 需要查询，session state 适合 KV，完整 tool call/context 适合 Doc，LLM 则可以通过 MCP 使用这些能力。

这个顺序必须保持：先有可验证的 DBMS，再增加 Agent client。自然语言不会替代 schema、parser、transaction 或 persistence；它只是产生结构化数据库操作的一种上层入口。
