---
title: 1. Page、Record 与 Slotted Page
description: 从固定大小页推导 header、slot array、record 区与空间检查。
---

存储系统不会为每行单独向 OS 请求一块内存或文件。数据库以固定大小 page 作为分配、读取、写入和缓存的基本单位。ppdb 的关系页是 512B，总页数 128。

## 为什么是 page

教材中的 page abstraction 隔离了 logical record 与底层 block/IO。即使 ppdb native 当前把页放在 static buffer、ppos 把页放固定内存区，core 只使用 page number 和 page provider。

page number 是稳定的逻辑句柄，page pointer 是当前宿主中的瞬时地址。持久化格式保存 page bytes/page references，不保存进程虚拟地址。

## Slotted page

变长 record 不能只按固定下标排列。ppdb 使用页头 + slot array + 反向增长 record 区：

```text
0                 slot_end       record_start             512
+-----------------+--------------+--------------------------+
| header (40B)    | slots ->     | free |     <- records   |
+-----------------+--------------+--------------------------+
```

每个 slot 保存 record offset 和 metadata。插入新 record 时：

```text
required = slot_size + record_size
free     = record_start - slot_end
require required <= free
```

然后 slot 向右增长，record_start 向左移动。两者相撞就是 page full，不能覆盖后继续写。

## Header 是页内 catalog

页头保存 page/table identity、slot count、free boundary 和 next page。多页 table 通过 page chain 连接。`db_page_init` 建立空页 invariant；`db_page_space` 只依据 header 计算可用空间。

任何从 PDB4 读入的 header 都是不可信 bytes。page number、table id、slot count、offset 和 next pointer 必须先验证范围，否则后续 pointer arithmetic 会越过 page pool。

## Record layout

ppdb 当前列类型是 32 位 INT 与固定 32B STR，record size 由 catalog 的列类型求和。column offset 是之前各列宽度的 prefix sum：

```text
offset(col_i) = sum(size(col_j), j < i)
```

`db_col_ptr` 根据 table schema 计算地址，`db_col` 再按类型读取。SQL executor 不手写 offset，这保证 INSERT、WHERE、projection 使用同一 layout contract。

## 删除与压缩

删除会移除 slot，并移动页内 record 消除空洞。压缩提高空间复用，却使 record pointer 和 slot index 都不稳定。它直接引出下一章的问题：索引究竟应该保存什么身份？

## 实验

手算一个三列 `(INT, STR, INT)` record 的大小。给定空 512B page、40B header、8B slot，计算最多能放多少行以及剩余碎片。再对照真实边界测试；若实现容量与推导不同，检查 header/slot 常量或 record layout。
