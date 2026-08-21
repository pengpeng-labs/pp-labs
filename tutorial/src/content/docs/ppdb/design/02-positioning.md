---
title: 2. 独立数据库、嵌入组件与教学系统
description: ppdb 的四个身份以及它们共享的核心。
---

ppdb 不是只有一个部署形态。理解它需要区分产品身份和运行宿主。

## 四个身份

| 身份 | 证明方式 |
|---|---|
| 数据库原理实验 | page、SQL、index、transaction 主体用 pp 手写 |
| 独立嵌入式数据库 | native CLI 可编译为 `ppdb`，使用真实文件 save/load |
| ppos 系统组件 | 同一 core 使用固定页区和 ppos memory FS |
| Agent 数据后端 | SQL/KV/Doc 暴露为 MCP tools，`db ask` 形成 NL→operation 链路 |

“嵌入式”表示数据库运行在调用进程/系统内部，不通过独立数据库 server 和网络协议访问。SQLite 是这种产品形态的重要参照，但 ppdb 没有复制 SQLite 的 SQL 完整度、B-tree、journal 和并发能力。

## 独立性如何成立

native CLI 不依赖 ppos：它使用 `host_native.pp` 提供页区，使用 `host_file_native.pp` 调用 POSIX 文件 API。SQL、KV、Doc、transaction 和 PDB4 全部来自与 ppos 相同的 core 文件。

如果宿主机版本只有一个简化 parser 或内存 mock，它就不能证明 ppdb 是独立数据库。当前双宿主共享完整语义，因此一个 SQL 修复必须同时作用于 CLI、ppos shell 与 MCP。

## ppos 为什么是自然宿主

ppos 是单地址空间 libos/unikernel，没有传统多进程数据库 server 的价值。把 ppdb 作为 library 嵌入可以：

- 避免网络协议、socket server 和 authentication 层；
- 直接使用固定内存页区与内存 filesystem；
- 给 shell、app、Agent 和 MCP 共享一个本地数据状态；
- 保持资源使用确定。

代价是数据库与宿主共享故障域，没有进程隔离。ppdb 的 raw pointer 错误可能影响整个 ppos，这也是测试与镜像预检必须严格的原因。

## 不是什么

- 不是分布式数据库：无复制、分片和一致性协议；
- 不是网络数据库：无 wire protocol 和远程连接；
- 不是 vector database：无 embedding index 或 similarity search；
- 不是完整 document database：Doc 没有 query planner 或 secondary index；
- 不是“LLM memory framework”：数据模型、持久化和事务仍是普通数据库责任。

把这些边界写进教程，是为了让设计取舍可以被检验，而不是降低项目价值。
