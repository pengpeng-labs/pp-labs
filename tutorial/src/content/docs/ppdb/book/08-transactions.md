---
title: 8. Before-image UNDO 与 ACID 边界
description: 单会话事务如何回滚，以及为什么它不是完整恢复系统。
---

transaction 把多个操作视为一个状态转换：要么全部生效，要么都不生效。

```sql
BEGIN;
UPDATE people SET city='London' WHERE id=7;
ROLLBACK;
```

ppdb 在 BEGIN 保存整个数据库的 before-image：关系页、catalog、page allocator、KV、Doc 和 index definitions。ROLLBACK 恢复快照并重建派生索引；COMMIT 丢弃快照。

## 从状态机理解事务

```text
Idle --BEGIN--> Active(before_image)
Active --statement--> Active(mutated live state)
Active --COMMIT--> Idle(keep live state)
Active --ROLLBACK--> Idle(restore before_image)
```

嵌套 BEGIN 没有定义，必须失败。活动 transaction 中 save/load 被拒绝，避免 live state、snapshot 和外部 image 三种时间点互相覆盖。

## 为什么全库快照可接受

UNDO log 通常只记录被修改对象的 before-image，减少复制。ppdb 的固定关系页仅 64 KiB，加上有限 catalog/KV/Doc，整库 snapshot：

- 实现路径单一；
- rollback 时间和内存上界确定；
- 不会漏记某个 mutation site；
- 适合单会话教学环境。

代价是 BEGIN 即复制整个状态，写少量数据也付出固定成本。它不是大型 DB 的可扩展策略。

## ACID 审计

| 属性 | ppdb 当前能力 | 缺失 |
|---|---|---|
| Atomicity | session 内 COMMIT/ROLLBACK all-or-nothing | crash 后 undo/redo recovery |
| Consistency | parser、schema、page/index invariant | 通用 constraint/foreign key |
| Isolation | 单会话、单写者，逻辑 table lock state | 多连接、隔离级别、deadlock |
| Durability | 显式 save/load 可跨进程 | WAL、fsync、torn-write recovery |

这张表防止“支持 BEGIN 就支持完整 ACID”的错误宣传。

## 锁的当前含义

`db_tx_table_lock` 表达活动 transaction 涉及的 table 边界，但没有真正的 concurrent sessions 和 scheduler interleaving，因此它不是 strict 2PL 实现。没有并发，就没有 dirty read、non-repeatable read 或 phantom 的运行场景。

保留 lock state 的价值是明确未来接口，而不是声称已经实现 isolation protocol。

## 派生结构的恢复

snapshot 保存 index definition，不依赖当前有序 entries；ROLLBACK 恢复 heap/catalog 后调用 `db_index_rebuild_all`。正确顺序是先恢复事实，再重建 derived state。若先恢复 index bytes，再恢复 rows，可能短暂或永久不一致。

## 实验

在一个 transaction 中同时 UPDATE relation、PUT KV、PUT Doc、CREATE INDEX，再 ROLLBACK，确认四类状态全部恢复。重复一次 COMMIT，确认 live state保留。随后尝试 nested BEGIN 和 transaction 内 save/load，确认在修改外部状态前失败。
