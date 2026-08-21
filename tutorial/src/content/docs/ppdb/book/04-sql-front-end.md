---
title: 4. SQL 前端：从文本到类型化语句
description: 用编译原理方法实现一个有明确边界的 SQL 子集。
---

SQL 是声明式语言。数据库先把文本转换成结构化 statement，再由 catalog resolution 和 executor 决定如何访问数据。直接在字符串上边匹配边修改 page，会把语法、名称、类型和副作用混成一个不可验证过程。

## 一个小文法

简化 SELECT：

```text
select   ::= SELECT projection FROM ident where? limit? to-json?
projection ::= "*" | ident ("," ident)*
where    ::= WHERE ident cmp literal
cmp      ::= "=" | "!=" | "<" | ">" | "<=" | ">="
literal  ::= integer | string
```

parser 的任务是识别这套 grammar，不是猜测用户意图。当前 WHERE 只允许一个 condition；遇到 AND/OR 应明确拒绝，而不是只执行前半段。

## Typed statement representation

`DbStmtKind` 区分 CREATE、INSERT、SELECT、UPDATE、DELETE、CREATE INDEX 和 transaction control；`DbValue` 区分 INT/STR；`DbCmpOp` 区分比较符。pplang 的 enum/switch 让 executor 必须穷尽 statement kind。

```text
SQL text
  -> tokens / parser buffer
  -> DbStmtKind + fields + DbValue + DbCmpOp
  -> catalog resolution
  -> execution
```

这与龙书的 compiler front end 相同：concrete syntax 被降低为 AST/IR，后续阶段不再重新解析字符。

## Parser 拥有缓冲区

parser 使用自己的有界 static buffer，不依赖 ppos 某个固定 input address。字符串 literal 和 identifier 的生命周期必须覆盖 executor 使用；容量检查应先于 copy，末尾为 C glue 保留 NUL 时不能少算一个 byte。

有界 parser 是 ppos 的资源选择，也是安全合同：超长 SQL 必须失败，不能截断成另一条合法语句继续执行。

## 语法正确不等于语义正确

`SELECT missing FROM people` 符合 grammar，但 catalog resolution 会因 unknown column 失败。`WHERE name >= 7` 可能 grammar 合法，却违反 column/literal type compatibility。

因此至少分三类错误：

- lexical/syntax：token 或 grammar 不成立；
- name/type：table、column、value domain 不成立；
- execution/storage：容量、page 或 transaction 状态不允许操作。

Agent 生成的 SQL 也必须经过三层，不能因为来源是 LLM 就绕过检查。

## 实验

为 SELECT grammar 列出每个 optional clause 的最小正例和 delimiter 反例。加入未知 table/column 与类型不匹配 case，确认错误落在 parser 之后、page 修改之前。
