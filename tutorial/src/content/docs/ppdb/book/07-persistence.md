---
title: 7. PDB4、持久化与防御性加载
description: 二进制镜像、两遍验证、版本迁移以及 durability 边界。
---

内存数据库要跨进程恢复，必须把 abstract state 编码成 bytes。PDB4 是 ppdb 的整库镜像：catalog/列名、KV、Doc、index definition 和已分配关系页区按固定顺序保存。

```text
magic/version
catalog + column metadata
KV slots
Doc slots
index definitions
page allocator + page bytes
```

## 序列化合同

格式要明确每个字段的 width、byte order、count 和边界。CSAPP 中的 data representation 在这里成为文件兼容合同：写端的 `u32` 编码必须与读端 `rd_u32` 对称；pointer 不能写入镜像，因为另一个进程/宿主的地址不同。

可持久化事实与派生状态应分开：

- 保存：schema、rows、KV/Doc bytes、index definition；
- 不保存：row pointer map、ordered index content、临时 scanner；
- load 后重建：row pointer map 与 index entries。

少保存派生数据能降低格式复杂度，也避免同时维护两份事实来源。

## 为什么 load 分两遍

文件输入不可信。若边读边写 global state，在最后发现截断，数据库会留下半个 catalog 和旧/新 page 混合状态。

ppdb 使用 validate-then-commit：

```text
pass 1: parse and validate every count/reference/length, mutate nothing
pass 2: read the already validated image into live state
```

第一遍检查 magic、版本、table/column/page count、类型 tag、page reference、index definition 和完整文件长度。只有全部通过才进入第二遍。

这个结构类似 transaction 的 all-or-nothing，但针对外部镜像输入。它的 invariant 是：`load(image)` 要么得到完整合法新状态，要么保持原数据库状态不变。

## 版本兼容

PDB4 loader 兼容 PDB1/PDB2/PDB3。旧格式没有真实 column name 时迁移为 `c0...`，旧 slot 没有 row ID 时分配新 ID。migration 不是简单“少读几个字段”，而是把旧合法 state 映射为满足新 invariant 的 state。

升级时应满足：

```text
decode_vN(image) -> abstract_state
upgrade(abstract_state) -> current_valid_state
```

不要让 executor 到处判断版本；版本差异应在 load boundary 被消化。

## Persistence 与 durability

native file provider 能真实写文件并跨进程 load，这证明 persistence。ppdb 没有 WAL、fsync protocol、atomic rename 或 torn-write recovery，因此不承诺 crash-safe durability。

即使 `write()` 返回成功，data 也可能只在 OS cache；断电时 header/page 可能只写一部分。OSTEP 的 filesystem/crash consistency 内容解释了为什么“有文件”与“durable commit”之间还有协议。

## 实验

保存一个包含三模型和 index definition 的 PDB4，逐段截断、修改 count、page reference 和 type tag。每次 load 都应失败且旧数据库保持不变。再加载 PDB1/PDB2/PDB3 fixture，验证迁移后的 schema、row ID 和 index rebuild。
