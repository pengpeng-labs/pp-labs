---
title: SQL 前端与执行器
description: 从字符缓冲到类型化语句，再到 scan/filter/project。
sidebar:
  order: 4
---

ppdb 支持 CREATE/DROP、INSERT、SELECT、UPDATE、DELETE、CREATE INDEX 和事务控制语句。WHERE 当前是一个条件，操作符为 `= != < > <= >=`。

```sql
CREATE TABLE people (id INT, name STR, city STR);
INSERT INTO people (city,id,name) VALUES ('Paris',7,'Ada');
SELECT city,id FROM people WHERE id>=7 TO JSON;
```

parser 使用自身拥有的有界静态缓冲，不依赖 pp-os 固定地址。值、比较符和语句种类分别由 `DbValue`、`DbCmpOp`、`DbStmtKind` 表示，执行器通过穷尽 `switch` 处理。

表目录保存真实列名。INSERT 可以改变列顺序，SELECT 可以重排投影，WHERE 与 UPDATE 都按名称解析列号。未知列会报错，不再退化为第一列。

`TO JSON` 复用同一过滤与投影路径，输出对象数组：

```json
[{"city":"Paris","id":7}]
```

native CLI、pp-os shell 和 MCP SQL 工具使用同一 parser 与执行器，不存在宿主机专用的简化 SQL 方言。
