---
title: 14. 综合实验：持久化 Agent Session
description: 用 Relation、KV、Doc、事务、PDB4 和 MCP 完成一个数据闭环。
---

综合实验建立一个三轮 Agent session。目标不是调用一个真实模型，而是把模型前后的数据合同做完整：metadata 可查询、完整内容可回放、current state 可点查、一次 turn 原子更新、重启后可恢复。

## 1. 设计数据

受当前 4-column 上限约束：

```sql
CREATE TABLE messages (
  session STR,
  role STR,
  seq INT,
  doc_name STR
);
CREATE INDEX messages_seq ON messages(seq);
```

每轮完整内容保存为 Doc：

```text
msg-s1-1 -> {"role":"user","content":"list tables"}
msg-s1-2 -> {"role":"assistant","tool":"sql","args":"..."}
msg-s1-3 -> {"role":"tool","result":"..."}
```

KV 保存：

```text
current-session -> s1
session-s1-next -> 4
```

## 2. 写入一个 turn

```text
BEGIN
  doc_put(full message/tool call)
  INSERT metadata row
  kv_put(next sequence)
COMMIT
```

在 INSERT 前故意让 Doc 超长，或者让 metadata table full。失败时 ROLLBACK，确认三种模型都没有部分变化。

## 3. 查询与关系代数

```sql
SELECT role,doc_name FROM messages WHERE seq>=2 TO JSON;
```

写出：

```text
Project[role,doc_name](Select[seq >= 2](Scan[messages)))
```

确认 planner 使用 messages_seq index，logical result 与 seq scan 等价。随后按返回 doc_name 调用 Doc get，完成 metadata 到完整内容的应用级引用。

## 4. 持久化与重启

执行 `save session.pdb`，退出 native CLI，启动新进程 load。验证：

- catalog 和 column names 恢复；
- 三条 relation rows 恢复；
- KV current/next 恢复；
- Doc JSON bytes 完整；
- index definition 恢复，entries 从 rows 重建；
- row ID/address map 在新进程重新建立。

这一步同时检验 logical state、binary representation 和 derived state rebuild。

## 5. 通过 MCP 使用

在 ppos 中让 tools/list 暴露 sql/kv/doc，再依次：

1. KV 取得 current session；
2. SQL 查询 message metadata；
3. Doc 取得完整 tool result；
4. 将 structured result 返回 Agent。

模型只提出 tool calls；每次调用仍经过 argument、SQL、schema、capacity 和 transaction validation。

## 6. 能证明什么

完成实验说明：同一 ppdb instance 能为一个 Agent workflow 提供三模型、会话原子性、显式持久化与双宿主工具接口。

它不能证明：断电不丢 committed turn、多 Agent 并发隔离、远程访问安全、Doc field query、向量检索或无限 context。把完成项和未承诺项同时写出，才是一份可信的系统实验报告。

## 延伸

增加 session summary relation、按 tool/status 查询的字段，并讨论哪些 Doc 字段值得 schema 化。然后设计 WAL 所需的最小 log record，但暂不实现：先说明 BEGIN/UPDATE/COMMIT 如何恢复，再决定 v0.4 是否需要这一复杂度。
