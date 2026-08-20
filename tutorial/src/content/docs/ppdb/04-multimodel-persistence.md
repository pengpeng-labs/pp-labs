---
title: KV、Doc 与持久化
description: 小型多模型接口以及 PDB4 镜像的验证与兼容。
sidebar:
  order: 5
---

KV 是最多 64 项的有序数组，key 最多 31B，value 最多 63B。Doc 最多 16 项，名字最多 31B，内容最多 127B。槽末字节固定保留给 NUL，更新短值会先清空旧槽。

Doc 存储层把内容视为紧凑 JSON 或字节串；它不声称完成 JSON schema 或语法验证。MCP 边界负责 JSON-RPC 的转义与封装。

## PDB4

镜像依次保存：表目录与列名、KV、Doc、索引定义、已分配页区。索引内容不保存，因为它可以从表行和稳定 row ID 重建。

load 分为两遍。第一遍验证 magic、所有计数、表类型、页引用、索引定义和文件长度，不修改数据库；第二遍才提交全局状态。失败的 load 不会留下半张表或被截断的 KV。

PDB4 加载器兼容 PDB1、PDB2 和 PDB3：旧列名使用 `c0...` 迁移，旧 slot 会补 row ID。
