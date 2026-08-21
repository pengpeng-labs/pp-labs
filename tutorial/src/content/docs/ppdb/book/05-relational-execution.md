---
title: 5. 关系代数与执行器
description: 从 selection、projection 推导 scan/filter/project cursor。
---

关系代数给 SQL 执行提供较小的语义核心。对：

```sql
SELECT city,id FROM people WHERE id >= 7;
```

可写成：

```text
Project[city,id](Select[id >= 7](Scan[people]))
```

SQL 描述结果，关系代数表达 logical operations；physical executor 决定这些 operation 怎样迭代 page 和 index。

## Iterator model

教学数据库常把 executor 写成 open/next/close iterator。ppdb 使用 cursor value：

```text
cursor = db_row_cursor_open(table)
while (row = db_row_cursor_next(&cursor)):
  if db_match(row, predicate):
    project(row, columns)
```

`DbRowCursor` 可以包装 seq scan 或 index scan，consumer 不需要知道物理 access path。这是一种 volcano/iterator 思想的精简实现。

## Selection

filter predicate 包含 column、operator、literal。`db_match`：

1. 根据 schema 找 column type/address；
2. 用类型对应 comparator 得到三向比较；
3. `db_cmp_matches` 将比较结果解释为 `= != < > <= >=`。

把 comparator 与 operator mapping 分开，可以复用 INT/STR comparison，并避免每个 executor 重写六种条件。

## Projection

projection 只输出用户选择的 attributes，顺序由 SELECT list 决定。`*` 在 catalog resolution 后展开成所有真实列名，不应在 parser 中硬编码 `c0,c1...`。

`TO JSON` 复用同一 scan/filter/project 路径，只改变 result serializer：

```json
[{"city":"Paris","id":7}]
```

表格与 JSON 若走不同查询实现，很容易产生 WHERE 或 column order 语义分叉。

## CRUD 也是关系操作

INSERT 构造符合 schema 的 tuple；UPDATE 对 selection 结果修改指定 attribute；DELETE 从 selection 结果移除 tuple。它们都需要维护 derived state：row pointer map 和 index。

正确性条件不是“影响行数对”，还包括未匹配 row 不变、schema 之外 bytes 不变、索引与 heap 重新一致。

## 当前没有 logical optimizer

ppdb 不构建通用 operator tree，也不做 predicate pushdown、join reorder 或 expression simplification。单条件查询直接形成 cursor/filter/project pipeline。课程借关系代数定义语义，但不冒充完整 optimizer。

## 实验

对同一查询输出关系代数式，手工执行 scan/filter/project，再与 CLI 表格和 `TO JSON` 对比。接着增加 index，验证 logical result 不变、只有 access path 改变。
