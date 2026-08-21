---
title: 2. 稳定 Row ID 与扫描器
description: 区分记录身份、物理位置和迭代状态。
---

关系模型把 tuple 看作 relation 的成员，不关心它位于哪个 page byte。物理实现却必须定位 record。删除压缩后地址和 slot 都会变化，因此二者都不能直接充当稳定 identity。

## 三种标识不要混淆

| 标识 | 稳定性 | 用途 |
|---|---|---|
| record pointer | page compact/load 后变化 | 当前一次读取 |
| `(page,slot)` | slot 删除/移动后变化 | 扫描位置 |
| row ID | record 生命周期内稳定 | index 与逻辑定位 |

ppdb 把 16 位 row ID 放在 slot metadata 高位，低 16 位保存 record length。0 为旧镜像迁移保留。`db_next_rowid` 分配新身份，`db_row_ptr[rowid]` 是可重建的当前地址 cache。

## 为什么 index 保存 `(key,rowid)`

若 index 保存 pointer：page compact 后成为悬空地址。若保存 slot：删除前一项后 slot number 改变。保存 row ID 后，index entry 保持逻辑引用，再通过 `db_find_row` 或 row pointer map 找当前位置。

```text
index key -> rowid -> current record address
```

这与数据库教材中的 record identifier 思想一致：访问路径引用稳定 RID，而不是暴露易变的内存实现。

## Row pointer map 是派生状态

`db_row_ptr` 可以从 pages/slots 重建，因此不进入持久化事实来源。load、rollback 或 compact 后调用 rebuild，重新建立：

```text
for every live slot:
  row_ptr[rowid(slot)] = address(record(slot))
```

派生结构不必持久化，但必须保证重建是确定且完整的。若镜像中出现重复 row ID，最后写入会掩盖前者，因此 validation 应拒绝违反唯一性的状态。

## Scanner 是显式值

`DbScan` 保存 table id、当前 page、slot 与 last row ID。调用方持有 scanner，而不是依赖一个全局 cursor：

```text
scan1 = open(table_a)
scan2 = open(table_b)
next(scan1)
next(scan2)
```

这使查询可以嵌套或交错，也是把 execution state 从隐藏 global 变成普通值的语言设计收益。

删除当前行后，scanner 必须回退/保持正确位置，因为后继 slot 已左移。否则会跳过一行。这个经典 iterator invalidation 问题需要专门回归测试。

## 实验

插入三行，记录 row ID；删除中间行触发 compact，再确认第三行地址改变但 row ID 不变，index 仍能定位。随后 save/load，验证 row pointer map 被重建而不是从旧进程地址恢复。
