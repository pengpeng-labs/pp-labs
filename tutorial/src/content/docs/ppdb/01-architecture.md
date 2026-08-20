---
title: 架构与边界
description: 一个 pp 数据库，两个宿主，三种数据视图。
sidebar:
  order: 2
---

ppdb 的目标不是缩小版 PostgreSQL，而是把数据库核心原理放进可读、可运行的系统程序。关系表负责结构化查询，KV 保存状态，Doc 保存紧凑 JSON 或字节串。

```text
SQL / KV / Doc
      |
schema + heap pages + ordered maps
      |
page provider + file provider
      |
host_native        host_ppos
```

## 双宿主

`host_native.pp` 使用 64 KiB 静态页区，文件层调用 POSIX API。`host_ppos.pp` 将同一组逻辑页映射到 pp-os 的固定内存区域，文件层接入内存 FS。

核心代码只依赖四个页操作：分配、取得地址、标脏和释放。SQL parser、执行器、索引和事务不区分宿主。这个边界让同一份 `.pp` 数据库既能独立运行，也能进入 unikernel。

## 有意保持的小规模

| 资源 | 当前上限 |
|---|---:|
| 关系页 | 128 × 512B |
| 表 | 8 |
| 每表列 | 4 |
| KV | 64 项 |
| Doc | 16 项 |
| 单列索引 | 8 个 |

固定上限不是伪装成无限容量，而是让裸机内存布局、失败路径和测试范围都可计算。
