---
title: 索引与事务
description: 单列有序索引、范围计划和会话级 before-image UNDO。
sidebar:
  order: 6
---

```sql
CREATE INDEX people_id ON people(id);
SELECT name FROM people WHERE id>=100;
```

首版索引只接受 INT 列。每个条目是 `(key,rowid)`，构建后以堆排序形成有序数组，查询用二分查找确定等值或范围起点。planner 只在 WHERE 类型与索引列匹配时选择索引，其他查询继续顺序扫描。

INSERT、UPDATE、DELETE 后会重建受影响表的小型索引。数据库上限只有 64 KiB 关系页，这个选择用简单、可验证的维护策略换取写放大；它不是面向大数据量的 B+ 树实现。

## 事务

```sql
BEGIN;
UPDATE people SET city='London' WHERE id=7;
ROLLBACK;
```

BEGIN 保存数据库级 before-image，覆盖关系页、表目录、KV、Doc、页分配器和索引定义。ROLLBACK 恢复快照并重建索引；COMMIT 丢弃快照。嵌套 BEGIN 会失败，活动事务期间 save/load 会被拒绝。

这是单会话、单写者的粗粒度 UNDO 与表锁边界，不是磁盘崩溃恢复。没有 WAL 和 fsync，就不能宣称完整 ACID durability。
