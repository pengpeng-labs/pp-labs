---
title: 6. Access Path、索引与 Planner
description: 从稳定 RID、有序数组和 lower_bound 推导等值与范围扫描。
---

没有索引时，selection 必须检查表中每一行，代价近似 `O(N)`。索引提供从 search key 到 record identity 的辅助 access path。ppdb 首版索引是有序 `(int key, rowid)` 数组。

```sql
CREATE INDEX people_id ON people(id);
SELECT name FROM people WHERE id >= 100;
```

## 索引 invariant

对每个 entry i：

```text
keys[i] <= keys[i+1]
rowids[i] identifies a live row
column(rowids[i]) == keys[i]
```

重复 key 用 row ID 保持多个 entry。index definition 保存 name/table/column；index content 是可从 heap 重建的 derived data。

## Build 与排序

`db_index_rebuild` 顺序扫描 table，收集 `(key,rowid)`，再使用 heap sort 形成有序数组。选择 heap sort 是固定内存环境下的取舍：原地、最坏 `O(N log N)`、无需递归分配；不是数据库教材要求索引必须 heap sort。

写操作后重建整个小型索引，复杂度和写放大高于增量维护，但实现更容易验证。对 64 KiB 关系页区，这是有意的 scale tradeoff。

## lower_bound 与范围

二分查找寻找第一个满足边界的位置：

```text
lower_bound(key, inclusive=true)  -> first value >= key
lower_bound(key, inclusive=false) -> first value > key
```

等值扫描从第一个 `>= key` 开始，在 key 改变时结束；`>=`/`>` 从起点向后；`<`/`<=` 可以限制结束边界。每个 index row ID 再映射到当前 record。

## Planner 是合法性 + 代价选择

当前 rule-based planner 只在以下条件同时成立时选 index：

- 有 WHERE；
- predicate column 存在单列 index；
- column 与 literal 都是 INT；
- operator 能由 index scan 表达。

否则回退 seq scan。`db_last_plan_index` 让测试观察选择，而不是从结果猜测。

严格来说，小表上 seq scan 可能比 index 更便宜，成熟 optimizer 会用 statistics 和 cost model。ppdb 当前没有 row-count/selectivity cost estimation，所以“存在合法索引就用”是 rule-based，不应称为 cost-based optimizer。

## 为什么不是 B+ tree

B+ tree 适合 page-oriented 大数据：高 fanout、动态 split/merge、range leaf chain。ppdb 的有序数组重建无法扩展到大型写负载，但更适合讲清 key、RID、ordering、binary search 和 planner 的最小闭环。未来迁移 B+ tree 时，logical index contract 和 cursor interface可以保留。

## 实验

对相同数据分别运行无索引、建索引后等值、范围和 STR predicate。断言结果一致，并检查 `db_last_plan_index` 只有合法 INT predicate 使用 index。更新 indexed key 后，再验证 entry key 与 heap row 一致。
