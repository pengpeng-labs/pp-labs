---
title: 13. 怎样验证一个数据库
description: Golden、invariant、损坏镜像、计划观察和 Rust 语义 Oracle。
---

数据库 bug 常有延迟：一次错误写入可能到 scan、index rebuild、save/load 或 rollback 时才暴露。测试必须围绕 invariant 和状态序列，而不是单次 CRUD demo。

## 测试层次

| 层次 | 主要 Oracle |
|---|---|
| parser | statement kind/field 或明确 syntax error |
| catalog | name/type resolution 与 schema state |
| heap | slot/record/page invariant、scan result |
| index | ordering、row ID、planner access path |
| transaction | before/after state equality |
| persistence | cross-process round trip、corruption rejection |
| host | file/page provider contract |
| Agent | MCP envelope、structured result、无旁路写入 |

## Golden 与结构断言

CLI golden 模拟用户工作流，比较表格/错误输出。它覆盖集成，但不应承担全部诊断。索引测试应直接检查 `db_last_plan_index`，transaction 测试应比较 relation/KV/Doc/catalog，而不是只看最后一条 SELECT。

## 状态机测试

事务、page allocator、save/load 都有状态。测试 sequence 比单 operation 更重要：

```text
insert -> delete -> insert -> scan
begin -> update -> rollback -> index lookup
save -> mutate -> load -> query
load corrupt -> query old state
```

每条 sequence 都应先写预期 invariant。

## Corruption testing

对 PDB4 系统修改 magic、version、count、page id、slot offset、index column、文件长度。目标不仅是“不崩溃”，还要保证 load 失败后旧 state 完全不变。

边界 case 包括最后一页、page full、KV/Doc full、最大名称/值、空字符串、删除后复用和 row ID migration。

## Rust 对照实现

`tools/ppdb-ref` 是高层语义 oracle：相同 command sequence 在 Rust 与 ppdb 上产生相同 logical result。它不复制 page layout，否则两个实现可能共享同一种物理 bug。

```bash
cargo test --manifest-path tools/ppdb-ref/Cargo.toml
```

差异可以帮助分类：Rust/pp 都错可能是 spec/golden 问题；只有 pp 错可能是 parser、raw memory 或 persistence；logical result 一致但 image 损坏则是 storage-only bug。

## 哪些还应补强

未来可增加 model-based random sequence：随机 CREATE/INSERT/UPDATE/DELETE/KV/Doc/BEGIN/ROLLBACK，Rust model 计算预期 state，ppdb 执行后比较。固定容量使状态空间比工业 DB 更适合这种测试。

## 验证命令

```bash
bash ppdb/tests/run_tests.sh
cargo test --manifest-path tools/ppdb-ref/Cargo.toml
```

测试通过表示当前声明的语义被覆盖，不表示未实现的 WAL、并发隔离或任意 SQL 已正确。
