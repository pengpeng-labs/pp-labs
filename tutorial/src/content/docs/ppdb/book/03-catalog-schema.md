---
title: 3. Catalog、Schema 与 Tuple
description: 把关系模型中的表、列和类型落实为目录与记录布局。
---

关系模型把 relation 定义为同一 schema 下 tuple 的集合。schema 给 attribute 命名并规定 domain。SQL 中的 table/column/type，必须在存储层变成 catalog metadata。

```sql
CREATE TABLE people (id INT, name STR, city STR);
```

对应 conceptual schema：

```text
people(id:int, name:str32, city:str32)
```

## Catalog 保存什么

ppdb 的 table catalog 保存：table name、column names、column count、column types、first/last page。当前上限 8 tables、每表 4 columns，让 catalog 能用固定数组表达。

表名/列名必须拥有稳定存储，不能指向 parser 的临时 input buffer。`db_tname_buf`、`db_tcol_buf` 保存 bytes，catalog 中地址指回这些稳定区域。

这也是 lifetime 问题：SQL parser 消费命令后，schema 仍长期存在。数据库不能把 request buffer 的借用误当 owned metadata。

## 名称解析

执行 `SELECT city,id FROM people` 时：

1. `db_find_table` 把 table name 解析成 tid；
2. `db_col_idx` 在该 table schema 中解析每个 column；
3. 找不到名称就报错；
4. executor 只使用 tid/column id 与类型。

过去“未知列退化到第一列”会静默返回错误数据，比显式失败更危险。名称解析必须是 total lookup returning found/error，不能用合法 id 0 兼作 not-found。

## Tuple 与列顺序

relation 的 attribute 有名称，INSERT input 可以改变列出现顺序：

```sql
INSERT INTO people (city,id,name) VALUES ('Paris',7,'Ada');
```

executor 要按 column name 把 value 放入 schema 对应 offset，而不是按输入位置直接复制。SELECT projection 同理可以重排列。名称到 ordinal 的 mapping 是 logical schema 与 physical record 的桥。

## 类型 domain

INT 与 STR 不只是 width。comparison、serialization、index eligibility 都依赖类型。INT predicate 可以使用 ordered numeric index；STR 目前只能扫描并按受限字符串比较。planner 不能因为 bytes 都能比较就把 STR 当 INT key。

## 实验

建立三列表，使用乱序 INSERT，再以另一顺序 SELECT。随后查询未知列，确认失败而不是读取 c0。最后查看 record bytes，区分“SQL 输入顺序”和“schema physical order”。
