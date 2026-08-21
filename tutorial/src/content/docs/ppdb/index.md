---
title: ppdb 数据库教程
description: 从数据库原理到多模型、双宿主和 Agent 嵌入式数据层。
---

# 从一页记录到 Agent 数据层

ppdb 是用 pplang 编写的小型多模型嵌入式数据库。它首先是一台可以独立运行的 DBMS：拥有页式堆表、catalog、SQL parser/executor、索引、事务和持久化；随后才成为 ppos 中 Agent 与 MCP 的数据后端。

```text
                    native CLI
                        │
SQL ─────┐              │
KV ──────┼── ppdb core ─┼── PDB4 image
Doc ─────┘              │
                        │
                    ppos / MCP / Agent
```

项目有两段来源。第一段来自学完数据库原理后的问题：如果不调用现成数据库，能否亲手把 relation、page、record、scan、index、transaction 和 recovery boundary 做成一个可运行系统？第二段来自 Agent 工程实践：对话、状态、配置和工具结果天然不是一种形态，是否能让同一嵌入式数据层提供 SQL、KV 和 Doc，而不是让 Agent 管理散落文本文件？

## 这套课程讲什么

课程不是 ppdb 功能列表，而是沿数据库理论建立实现：

1. 从关系模型和存储层次推导 schema、tuple、page 与 slotted page；
2. 从关系代数推导 scan/filter/project 与 SQL executor；
3. 从访问路径和代价推导顺序扫描、ordered index 与 planner；
4. 从持久化和 ACID 推导 PDB4 验证、before-image UNDO 与能力边界；
5. 从 Agent 数据形态推导关系/KV/Doc 的分工与 MCP tool contract；
6. 从数据独立性推导 native/ppos 双宿主。

每章遵循同一条路线：

```text
数据库问题
  -> 教材模型
  -> ppdb invariant
  -> pplang 数据结构与算法
  -> 设计取舍
  -> 反例与实验
```

## 学习顺序

先读“设计与定位”，尤其是[多模型融合到了哪一层](./design/03-multimodel-boundary/)。随后按 `ppdb Book` 顺序，从系统模型走到综合实验。已熟悉数据库课程的读者也不应跳过第 0 章：它定义了本书怎样区分 logical model、physical representation、persistence 和 durability。

## 当前能力边界

ppdb 是单进程、单用户、固定容量的嵌入式数据库，不是缩小版 PostgreSQL：

- 关系表最多 8 张、每表最多 4 列，关系页区为 128 × 512B；
- KV 最多 64 项，Doc 最多 16 项；
- SQL 是明确子集，WHERE 当前为单条件；
- 索引是单列 INT 的有序 `(key,rowid)` 数组，不是 B+ tree；
- 事务是单会话 before-image rollback，不提供并发隔离和崩溃恢复；
- Doc 保存 JSON/bytes，不实现 document query language 或 JSON schema；
- Agent 是客户端和工具调用者，不能绕过 parser、类型与存储校验。

这些上限不是需要隐藏的缺陷，而是让内存、失败路径和裸机宿主都可计算的课程边界。

## 运行

```bash
cd pplc && cargo build
cd ..
bash ppdb/tests/run_tests.sh
```

宿主机 CLI 与 ppos 共享 `db_core.pp`、`db_sql_parse.pp`、`db_sql_exec.pp`、`db_persist.pp` 和 `db_tx.pp`。实现入口见[源码与不变量地图](./reference/source-map/)。
