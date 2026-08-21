---
title: 11. MCP、db ask 与不可信 Planner
description: 自然语言怎样经过工具合同进入数据库，而不绕过语义检查。
---

`db ask` 把自然语言请求交给模型，模型选择 SQL/KV/Doc 工具，再由 ppdb 执行。最重要的设计不是 prompt，而是信任边界：LLM output 是不可信 input。

```text
user question
  -> model sees schema + tool definitions
  -> tool_call(name, structured args)
  -> MCP/JSON-RPC validation
  -> ppdb SQL/KV/Doc validation
  -> transaction/storage operation
  -> structured result
  -> model response
```

## MCP 是工具协议，不是数据库协议

ppdb 没有开放 SQL network server。ppos 的 MCP layer 把 `sql`、`kv`、`doc` 注册为 tools，Agent 通过现有 JSON-RPC/tool-call 通道使用本地嵌入数据库。

MCP 负责 tool discovery、argument envelope、result/error envelope；ppdb 仍负责 SQL grammar、schema、capacity、transaction 和 page invariant。两层错误不能混成一个“模型失败”。

## Schema grounding

模型若不知道真实 table/column，会生成 plausible but invalid SQL。`db_schema` 把 catalog 转成有限 schema text，作为 tool context。即使 grounding 完整，模型仍可能引用不存在列或类型不匹配，因此 executor 必须再次解析和校验。

```text
schema reduces invalid proposals
parser/catalog rejects remaining invalid operations
```

prompt 不是 authorization，也不是 type system。

## 三个工具为什么分开

- `sql`：声明式查询和关系 CRUD；
- `kv`：显式 get/put/del；
- `doc`：显式 named content get/put。

分开 tool contract 让模型表达意图，也让参数 validation 更具体。把所有操作塞进一个自由文本 command，会失去结构化 schema 和错误定位。

## `SELECT ... TO JSON`

JSON result 让模型无需解析人类表格。它复用 SQL 的 scan/filter/project，只替换 serializer，因此 table output 与 Agent output 具有相同 query semantics。

JSON encoding 必须处理 quotes、backslash 和 control characters。Doc content 是 JSON 时还要区分“作为 result string escape”与“作为嵌套 JSON value”两种语义，不能通过拼字符串碰运气。

## Side effect 边界

自然语言请求可能产生写操作。当前单用户系统没有角色权限、approval policy 或 query sandbox，因此课程应把 MCP 看作受信宿主内的工具接口，不声称适合暴露给任意远程 Agent。

稳健顺序是：parse arguments、validate operation、必要时 BEGIN、执行、检查结果、COMMIT/ROLLBACK，再返回 tool result。

## 实验

让模型提出三类错误：未知列、KV value 超长、非法 Doc argument。追踪错误分别在哪一层被拒绝，并验证数据库状态没有部分修改。然后比较相同 SELECT 的 CLI 与 MCP JSON 结果。
