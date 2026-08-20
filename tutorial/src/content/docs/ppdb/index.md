---
title: ppdb 数据库教程
description: 从页式堆表到 Agent 数据后端，用 pp 实现一个双宿主嵌入式数据库。
sidebar:
  order: 1
---

ppdb 是用 pp 编写的小型多模型嵌入式数据库。它同时提供关系表、KV 和 Doc 三种视图，在宿主机上是独立 CLI，在 pp-os 中是 Agent 与 MCP 的数据后端。

这套教程沿真实实现展开：

1. [架构与边界](./01-architecture/)：为什么同一数据库需要两个宿主。
2. [页、记录与扫描](./02-storage/)：512B 页、slot array、row ID 和删除压缩。
3. [SQL 前端与执行器](./03-sql/)：类型化 IR、投影、过滤与 JSON 输出。
4. [KV、Doc 与持久化](./04-multimodel-persistence/)：固定容量模型与 PDB4 镜像。
5. [索引与事务](./05-index-transaction/)：稳定行定位、范围计划和 before-image UNDO。
6. [Agent、MCP 与验证](./06-agent-testing/)：双宿主集成与对照测试。

:::note[实现边界]
ppdb 是单用户、进程内数据库。事务支持会话内原子回滚，不提供 WAL、fsync 崩溃恢复、多连接隔离或网络数据库协议。
:::
