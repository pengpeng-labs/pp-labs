---
title: Agent、MCP 与验证
description: 把数据库接入 pp-os，并用双实现测试语义。
sidebar:
  order: 7
---

pp-os 将 sql、kv、doc 注册为 MCP 工具。Agent 可以读取 schema、执行 SQL、保存会话文档和更新 KV 状态。`db ask` 把自然语言请求交给模型，再执行返回的工具调用。

## 构建与测试

```sh
cd pplc && cargo build
cd ..
bash ppdb/tests/run_tests.sh
cd ppos && make
```

host 测试包含 CLI golden、跨进程 PDB4、最后一页边界、KV/Doc 满容量、列名语义、索引计划、事务、删除复用与损坏镜像。

Rust 对照实现验证相同的高层语义：

```sh
cargo test --manifest-path tools/ppdb-ref/Cargo.toml
```

Rust 版本是 oracle，不复制 `.pp` 的页布局。这样失败时可以区分“数据库语义错误”和“裸内存实现错误”。

:::tip[阅读代码]
先读 `db_core.pp` 的页与扫描器，再读 `db_sql_parse.pp` / `db_sql_exec.pp`，最后读 `db_persist.pp` 和 `db_tx.pp`。这个顺序与数据从内存到查询再到恢复的方向一致。
:::
