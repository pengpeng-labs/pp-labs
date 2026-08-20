---
title: 页、记录与扫描
description: 理解 heap page、slot array、稳定 row ID 和空间复用。
sidebar:
  order: 3
---

每张表是一条页链。页头保存页号、表号、slot 数、记录区边界和下一页号；slot 从页头向后增长，记录从页尾向前增长。

```text
0         40              free                 512
+ header  + slot array -> | free | <- records +
```

slot 包含记录偏移和一个 32 位 metadata。metadata 的低 16 位是记录长度，高 16 位是稳定 row ID。PDB1/PDB2 镜像没有 row ID，加载时会迁移；PDB3 以后会保留它。

## 为什么需要 row ID

DELETE 会压缩 slot 和记录区，记录地址与 slot 下标都可能改变。索引若保存裸指针，第一次压缩后就会失效。索引因此只保存 `(key, rowid)`，取行时再由表页查找 row ID。

## 扫描器是值

`DbScan` 保存表号、当前页、slot 和最后返回的 row ID。调用方持有扫描器，因此两个查询可以交错前进；它不再依赖全局扫描状态。

删除当前行时，ppdb 移走 slot、压缩页内记录并回退扫描位置。反复插入和删除同一行不会持续消耗新页。
