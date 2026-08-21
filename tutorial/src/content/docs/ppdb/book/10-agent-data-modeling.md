---
title: 10. Agent 数据如何建模
description: 根据访问模式把 session 数据分配给 Relation、KV 与 Doc。
---

Agent 不是一种新的存储介质。它产生的 messages、configuration、tool calls、context snapshots 仍要根据访问模式建模。多模型价值在这里才真正出现。

## 从问题而不是格式出发

先问怎样访问，再选模型：

| 数据 | 典型问题 | 模型 |
|---|---|---|
| message metadata | 某 session 最近 N 条？按 role 统计？ | relation |
| current session id | 给定 key 取当前值 | KV |
| model/config flags | 小量命名状态读写 | KV |
| 完整 tool call/result | 整体保存和回放 | Doc |
| context snapshot | 按 name/version 整体取回 | Doc |

如果未来要按 tool name、latency、status 查询，原本 Doc 中的字段可能需要提升为 relation columns。这是 schema evolution 的产品决策，不是数据库自动知道的事情。

## 一个最小 session schema

```sql
CREATE TABLE messages (
  session STR,
  role STR,
  seq INT,
  content STR
);
CREATE INDEX messages_seq ON messages(seq);
```

当前每表最多 4 列、STR 固定 32B，所以完整长 content 不适合直接放 relation。可以让 relation 保存可查询摘要/标识，把完整 message JSON 放 Doc：

```text
relation: (session, role, seq, doc_name)
doc:      doc_name -> full JSON bytes
kv:       "current-session" -> session id
```

这是一种应用级跨模型引用。ppdb 当前没有 foreign key 或跨模型 join，一致性由 transaction 和应用操作顺序维护。

## 原子更新

一次 Agent turn 可能同时：INSERT message metadata、PUT full Doc、更新 KV cursor。把三步放在一个 before-image transaction 中，任一步失败即可 rollback，避免“表里有消息但 Doc 丢失”。

当前 transaction 是单会话内存原子性；若随后还要持久化，COMMIT 后需要显式 save。crash-safe commit/save 仍未实现。

## Context 不是无限记忆

存下来不等于每轮都应全部喂给 LLM。关系查询负责筛选 metadata，KV 找当前状态，Doc 按需取完整内容；上层 Agent 再决定 context window。ppdb 提供可寻址数据，不负责 token budget、summarization 或 retrieval policy。

## 隐私与密钥

API key 不应作为普通 Doc 混入可查询 session dump。当前 pp-labs 的 key/config 边界属于宿主工程责任；教程必须区分 Agent content 数据与 secret management，ppdb 没有 encryption-at-rest 或 access control。

## 实验

为一个三轮 tool-calling session 设计 relation/KV/Doc 分配。列出每个读写 operation，再故意在第二步失败，验证 transaction 能否恢复一致状态。最后指出哪些约束数据库能保证，哪些仍由 Agent 应用保证。
