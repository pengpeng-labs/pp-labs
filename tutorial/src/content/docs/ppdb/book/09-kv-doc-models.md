---
title: 9. KV、Doc 与多模型生命周期
description: 两种专用数据结构、复杂度和统一事务/镜像边界。
---

KV 和 Doc 不是关系表的语法糖。它们服务不同访问模式，也使用不同物理结构。

## KV：有序 key/value 数组

KV 最多 64 项，key 最多 31B，value 最多 63B。key array 保持有序：

```text
get: binary search               O(log N)
put existing: search + replace   O(log N)
put new: search + shift          O(N)
delete: search + shift           O(N)
```

这借鉴 LevelDB 风格的 get/put/delete API，不是 LSM tree 实现。固定小容量下，数组比 skip list/LSM/SSTable 简单，iteration order 也确定。

更新短 value 前清空旧 slot，避免旧长 value 尾部残留。key/value buffer 最后一个 byte 为 NUL 保留，所以 payload capacity 比 array width 小 1。

## Doc：name 到完整 bytes

Doc 最多 16 项，name 最多 31B，content 最多 127B。`doc_put` 按 name 替换或追加，`doc_get` 整体读取。

存储层不解析 JSON field，因此复杂度和语义接近 named blob store：

- 可以保存紧凑 JSON 或其他 bytes；
- 不保证 JSON syntax/schema；
- 不支持 field predicate、projection、index；
- 不支持 partial update。

MCP 返回 JSON 时需要正确 escape envelope，和 Doc content 本身是否有效 JSON 是两个不同层次。

## 为什么不全放关系表

KV 的主要问题是确定 key 的点查，建立 table/schema/parser 会增加固定开销。Doc 的主要问题是完整 context/tool-call round trip，拆列会把频繁变化的 JSON schema 固化。

反过来，messages 需要按 role/time/session 查询时，Doc 全量扫描和应用解析不如 relation。选择模型应由访问模式驱动。

## 统一在哪里

KV/Doc 没有进入 relation heap page，但它们与 relation：

- 属于同一 ppdb instance；
- 被同一个 BEGIN snapshot/ROLLBACK 覆盖；
- 被同一个 PDB4 save/load；
- 通过同一 CLI/MCP lifecycle 暴露；
- 在 native 与 ppos 两个宿主中行为一致。

这叫统一生命周期，不叫统一查询引擎。

## 未来演进判断

当 KV/Doc 容量增长、需要 page cache、范围 scan、field query 或 incremental logging 时，固定数组会成为瓶颈。届时可把它们迁到 page-based structures，但应保持 API/transaction contract，并用 workload 证明复杂度值得增加。

## 实验

测试空 value、满容量、更新长值为短值、删除后插入、包含 JSON escape 的 Doc。然后在 transaction 中同时修改 relation/KV/Doc 并 rollback，观察物理结构不同但生命周期一致。
