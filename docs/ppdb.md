# pp-db 设计文档

> **利于 agent 的多模型嵌入式数据库**（RDB + KV + Doc，SQLite 风格）。
> pp-db 用 pp-lang 编写，本身是独立的小型数据库；pp-os 是它的首个宿主与展示场景——存 LLM 会话、上下文、配置、工具记录等 agent 数据。
> 目标：一行体现传统数据库原理（页存储/解析器/执行器），一行容纳 agent 时代的新东西（KV/Doc/JSON、NL→SQL、MCP 工具）。
> 本文档是 pp-db 的唯一设计台账。

---

## 1. 背景与动机

pp-os 现有能力：app 模型（注册表）、文件系统（含 fs_write_bin 二进制）、JSON 解析器、TLS + DeepSeek 调用（ds agent）、MCP 协议层、WASM 运行时、shell 脚本。

**Agent 数据是 pp-db 的核心场景**——它天然多形态：

| Agent 数据 | 自然形态 | 模型 |
|---|---|---|
| 会话消息（role/content/tool_calls 嵌套） | JSON 嵌套结构 | **Doc** |
| agent 状态、配置、session 指针 | 键值对 | **KV** |
| 消息历史、统计、跨会话查询 | 结构化表 | **RDB** |

三个痛点：
1. **上下文不持久**：agent 对话历史放内存缓冲（0x675000），重启即失。
2. **数据无结构**：key、配置、聊天记录是文本文件，无法查询、无法组合。
3. **Agent 缺工具**：LLM 能生成 SQL/KV/Doc 操作，但 pp-os 没有统一数据后端可执行。

**定位**：独立的小型多模型嵌入式数据库（SQLite 风格：进程内、单用户、单文件语义）。pp-os 是首个宿主（内存页区 + fs 持久化）；宿主机是第二宿主（经 `pp` 编译器运行，真实文件持久化）。数据量级 KB~MB，教学与演示并重。

---

## 2. 参考项目与取舍

| 参考 | 借鉴什么 | 不学什么 |
|---|---|---|
| **bustub**（CMU 15-445） | 执行器算子结构；LRU 仅作远期参考 | C++ 复杂度、完整并发（pp-os 单核协程用不到 2PL） |
| **SimpleDB**（MIT 6.830） | **核心结构参考**：heap file（页链 + slot array）、运算符执行器 | 无 |
| **nitcbase** | SQL 解析/执行分层教学结构 | 完整 SQL 语法 |
| **SQLite** | 单文件嵌入式工程组织、B+树页思想、SQL 子集边界 | 整体规模 |
| **LevelDB / RocksDB** | get/put/delete API、有序 key 结构 | LSM 合并（agent 小数据过重） |
| **LMDB** | 一个存储多视图的思路 | mmap 平台依赖 |
| **MongoDB / Doc 模型** | JSON 文档存储形态 | 分布式/复制 |
| **DuckDB / 列存** | 无 | 列存不适合小数据行场景 |

其他课程参考：MIT 6.830（ocw.mit.edu）、UT Austin CS386D、MiniDB（iusb.edu）、CMU 15-445 bustub。

**实现原则**：存储内核/RDB 主体用 pp-lang 手写（教学主线）；首版索引用稳定 row ID + 有序 `(key,rowid)` 数组，保持适合 64 KiB 数据规模的确定性实现。

---

## 3. 总体架构：三种数据视图，两类存储

```
┌──────────────────────────────────────────┐
│ 查询层（三接口）                           │
│  SQL（RDB）  │  kv_get/put/del  │  doc_*  │
├──────────────────────────────────────────┤
│ 模型层                                    │
│  表/行（schema + slot array）             │
│  键值（≤64 项有序数组）                    │
│  文档（≤16 项紧凑 JSON/字节串）            │
├──────────────────────────────────────────┤
│ 统一存储内核（传统原理主线）                │
│  关系表页式堆存储（128 × 512B）            │
│  页链 + slot array + 删除即时压缩          │
├──────────────────────────────────────────┤
│ 持久化层（宿主抽象）：db save/load         │
│  pp-os 宿主：内存页区 + fs_write_bin      │
│  宿主机宿主：真实文件                     │
└──────────────────────────────────────────┘

pp-os shell：
  ├─ sql <SQL>              RDB 查询
  ├─ db put/get/del          KV 接口
  ├─ db doc put/get          Doc 接口
  ├─ db save/load            持久化
  ├─ db ask <问题>           NL → 操作（v2）
  └─ MCP 工具：tools/call sql|kv|doc（v2）
```

### 3.1 双宿主

- **pp-os 宿主**：页区 0x680000（128 页 × 512B = 64KB）；持久化走 fs_write_bin（二进制）；`sql` 注册为 app；db 注册为 MCP 工具
- **宿主机宿主**：页用静态缓冲（host_native）；持久化走真实文件（host_file_native：POSIX open/write/read/lseek/close + fchmod）；经 `pp` 编译器（obj/run 目标 + libc）运行——**证明 pp-db 是独立数据库**（CLI 见 cli.pp，编译为 `ppdb` 可执行文件）

### 3.2 存储抽象（核心层宿主无关）

```
页提供者接口（宿主实现同名函数）：
  db_page_alloc() / db_page_ptr(n) / db_page_dirty(n) / db_page_free(n)
pp-os：固定内存区实现
宿主机：文件/内存实现
```

### 3.3 页格式（SimpleDB 风格）

```
行页：header(40B) + slot array(8B/槽) + 记录（从页尾生长）
KV/Doc 当前是独立固定容量数组，不占关系表页区。
```

v1 字段类型：`INT`（32 位）、`STR(n)`（定长 ≤ 32）
变长 `TEXT` 与数据库内 JSON 校验尚未实现，不属于当前格式承诺。

---

## 4. 版本规划

### v1 — 多模型内核（原理主线 + 三种模型基础）

**RDB（SQL 子集）**：
```
CREATE TABLE name (col TYPE, ...);
DROP TABLE name;
INSERT INTO name (cols...) VALUES (...);
SELECT cols FROM name [WHERE cond] [LIMIT n] [TO JSON];
UPDATE name SET col = expr WHERE cond;
DELETE FROM name WHERE cond;
```
- WHERE：单条件 `= != < > <= >=`，右侧为 int/str 字面量
- 执行器：seq_scan / filter / project / insert / update / delete

**KV**：`db put <k> <v>` / `db get <k>` / `db del <k>`（LevelDB API 风格，≤64 项有序数组）

**Doc**：`db doc put <name> <json>` / `db doc get <name>`（≤16 项；当前保存紧凑 JSON/字节串，不在存储层校验）

**基础设施**：内存页式堆表 + PDB4 二进制 `db save/load`（load 兼容 PDB1/PDB2/PDB3）
**集成**：`sql`/`db` 注册为 app；`db create/drop/list`

**验收**：
- [x] RDB CRUD + 单条件 WHERE/LIMIT 端到端可跑
- [x] KV put/get/del 生效
- [x] Doc put/get 生效
- [x] `db save` 后 `db load` 数据一致（重启不丢）
- [x] 宿主机宿主跑通（pp 编译器运行 + 持久化文件）

### v2 — Agent 结合（LLM 主线）

- **agent 数据模型落地**：`messages` 表（会话查询）+ kv（状态/配置）+ doc（完整会话 JSON）——替代 0x675000 内存缓冲
- **`db ask <自然语言>`**：LLM 看 schema → 生成 SQL/KV/Doc 操作 → 执行 → 结果回传（NL→数据闭环）
- **MCP 工具**：db 注册 `sql`/`kv`/`doc` 工具（agent 通过 MCP 调数据后端）
- **索引**：单列 INT `CREATE INDEX`；稳定 row ID、二分等值/范围计划、CRUD 后重建
- **JSON 输出**：`SELECT ... TO JSON`（结果直接喂 LLM）

### v3 — 单会话事务

- `BEGIN / COMMIT / ROLLBACK`：数据库级 before-image UNDO（会话内回滚）
- 单会话、单写者表锁状态；不宣称多连接隔离或崩溃恢复
- 聚合函数（COUNT/SUM/AVG）可选

---

## 5. 双宿主与 Rust 的辅助角色

**pp-db 主体用 pp-lang 编写**（语言/内核叙事统一）。Rust 做两件辅助事：

1. **`tools/ppdb-ref`（Rust 参考实现）**：同样的多模型语义用 Rust 写一遍，跑 golden tests 验证 pp-db 正确性——教学价值："同一数据库，两种实现对比"
2. **宿主机测试脚本**：批量 SQL/KV/Doc 用例驱动 pp-os（autotest 模式）+ 宿主机直接运行验证

---

## 6. 教学映射（三线合一）

| 数据库原理 | pp-lang 能力 | Agent/LLM |
|---|---|---|
| 页/记录/slot array | struct/数组/指针/内存布局 | 上下文表持久化 |
| 页提供者与镜像预检 | struct/数组/裸指针边界 | — |
| 稳定 row ID + 有序索引 | slot metadata/数组/二分 | 等值与范围检索 |
| SQL 解析器 | 词法/语法（复用编译器经验） | NL→SQL |
| 算子执行器 | 函数/多文件 | MCP 工具（sql/kv/doc） |
| KV/Doc 模型 | 接口抽象/多态思维 | agent 状态与记忆 |
| 双宿主 | 抽象层设计 | 数据随处可读 |

## 7. 明确不做

- ❌ 完整 SQL（无 GROUP BY/子查询/窗口函数——v1；v3 可加聚合）
- ❌ 并发连接/多用户（单用户嵌入式）
- ❌ Graph / Time-series / Vector 模型（agent 场景暂不需要；Vector 可作远期愿景）
- ❌ 列存储/向量化执行（DuckDB 路线）
- ❌ 网络协议（不开放数据库端口；pp-os 内经 MCP 出接口）

## 8. 里程碑

- [x] **P14-1** 存储内核：内存页式堆表 + 页提供者抽象
- [x] **P14-2** SQL lexer/parser（CREATE/INSERT/SELECT/WHERE/LIMIT）
- [x] **P14-3** 执行器（scan/filter/project/insert/update/delete）
- [x] **P14-4** KV 接口（≤64 项有序数组）+ Doc 接口（≤16 项固定槽）
- [x] **P14-5** `sql`/`db` 命令 + app 注册 + 表格式输出
- [x] **P14-6** 二进制 `db save/load`（fs_write_bin）——验证通过（整库镜像：表目录+KV+Doc+页区；单页/多页往返恢复正确）
- [x] **P14-7** 宿主机宿主跑通——验证通过（`pp run` JIT 与 `pp obj`+cc 双路径：建表/插入/扫描输出正确；地址通道 64 位化后宿主静态数据 >4GB 无截断）
- [x] **D-1/D-2 独立分发**：文件抽象层（hf_* 双宿主）+ 宿主机 CLI（cli.pp）——与 pp-os/MCP 共用完整 SQL 子集 parser/executor；`pp obj cli.pp && cc` 产出 `ppdb` 可执行文件
- [x] **D-3 宿主机测试脚本**：`tests/run_tests.sh`——验证通过（golden 测试 cases.txt vs expected.txt + 跨进程 save/load 往返；obj+cc 与 JIT 双路径）
- [x] **P15-1** `db ask`（NL→操作）+ agent 数据模型（messages/kv/doc）
- [x] **P15-2** MCP 工具（sql/kv/doc 三类）——验证通过（tools/list 4 工具；tools/call：sql SELECT 表格式返回/INSERT、kv put/get/del、doc put/get 含 JSON 转义；agent tools 定义同步）
- [x] **P15-3a** `SELECT ... TO JSON`（真实列投影/WHERE；CLI/MCP 共用）
- [x] **P15-3b** 关系索引（稳定 row ID 直接定位 + 单列 INT CREATE INDEX + PDB4 + CRUD 维护 + 等值/范围 planner）
- [x] **P16-1** 事务（BEGIN/COMMIT/ROLLBACK before-image UNDO）+ 单会话单写者表锁状态
- [x] **P16-2** `tools/ppdb-ref`（Rust 语义对照 + golden tests）
- [x] **P16-3** Starlight ppdb 独立课程（设计定位与理论地图 + 15 章 Book + 实现参考；数据库原理 × pplang × Agent）
