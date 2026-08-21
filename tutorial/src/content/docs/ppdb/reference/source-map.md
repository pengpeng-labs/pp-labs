---
title: 源码与不变量地图
description: ppdb 模块、数据结构、宿主接口与测试入口。
---

## 核心模块

| 文件 | 责任 | 关键结构/入口 |
|---|---|---|
| `db_core.pp` | catalog、heap page、scan、row ID、index | `DbScan`、`DbIndexScan` |
| `db_sql_lex.pp` | SQL token | lexer state |
| `db_sql_parse.pp` | SQL statement representation | `DbStmtKind`、`DbValue`、`DbCmpOp` |
| `db_sql_exec.pp` | resolution、scan/filter/project、CRUD、plan | `DbRowCursor`、`db_exec` |
| `db_kv.pp` | ordered key/value array | `kv_get/put/del` |
| `db_doc.pp` | named content slots | `doc_get/put` |
| `db_persist.pp` | PDB4 save/load/validation/migration | `db_validate_image` |
| `db_tx.pp` | whole-state before-image transaction | begin/commit/rollback |
| `host_native.pp` | native page provider | 64 KiB static pool |
| `host_ppos.pp` | ppos page provider | fixed memory region |
| `host_file_native.pp` | POSIX file adapter | extern file API |
| `host_file_ppos.pp` | ppos FS adapter | `hf_*` contract |
| `cli.pp` | independent database CLI | complete shared semantics |

## 状态所有权

```text
base facts:
  catalog + pages + allocator + KV + Doc + index definitions

derived state:
  rowid -> address map + ordered index entries + active cursors
```

load/rollback 必须先恢复 base facts，再重建 derived state。

## 从问题找代码

| 现象 | 首先查看 |
|---|---|
| page full/越界 | page header、`db_page_space`、insert |
| delete 后漏行 | `db_scan_delete` 与 cursor slot |
| index 返回旧行 | row ID rebuild、index CRUD rebuild |
| unknown column 读到 c0 | `db_col_idx` 与 executor error path |
| JSON 与表格结果不同 | shared row cursor/filter/project |
| load 后半状态 | `db_validate_image` 两遍边界 |
| rollback 漏 KV/Doc | `db_tx_begin/rollback` snapshot coverage |
| native 正常、ppos 失败 | page/file provider contract |
| MCP 与 CLI SQL 不同 | 是否绕过 shared parser/executor |

## 测试入口

```bash
bash ppdb/tests/run_tests.sh
cargo test --manifest-path tools/ppdb-ref/Cargo.toml
```

`tests/sql_semantics.pp` 直接观察列名、index plan、transaction 和三模型状态；golden/跨进程测试覆盖 CLI 与 PDB4；corruption fixtures 覆盖 loader 防御。
