<div align="center">
  <h1>pp-labs</h1>
  <p>面向系统软件的个人实验室：一门语言（pp），一个编译器，一个数据库，一个小 OS，以及配套教程。</p>
</div>

<p align="center">
  <a href="#中文">中文</a> |
  <a href="#english">English</a>
</p>

## <a id="中文"></a>中文

### 这是什么

pp-labs 是一个"面向系统软件的个人实验室"，每个产品独立发展、互相成就：

| 产品 | 说明 | 目录 |
|------|------|------|
| **pplang** | pp 语言规范（权威文档，可整份喂给 LLM 生成 `.pp`） | `pplang/` |
| **pplc** | pp 编译器：`.pp` → LLVM IR → 可执行 / JIT / 裸机 ELF | `pplc/` |
| **ppdb** | 用 `.pp` 写的小型嵌入式数据库（SQL/KV/Doc 多模型，可独立分发） | `ppdb/` |
| **ppos** | 用 `.pp` 自己写的迷你 unikernel（ppdb 的宿主与展示场景） | `ppos/` |
| **教程** | lang/（编译原理 + 语言本身）+ os/（boot → shell 的 OS 原理） | `tutorial/` |

两条主线贯穿始终：**教学友好** + **LLM 友好**。

### 目录结构

```
.
├── docs/          # roadmap.md（唯一任务台账）/ progress.md / baremetal.md / ppdb.md / app-model.md / stdlib.md
├── pplang/        # spec.md：语言规范（权威）
├── pplc/          # pp 编译器（Rust + inkwell / LLVM），含 src/ tests/ README
├── stdlib/        # 用 .pp 写的最小标准库（math.pp / string.pp）
├── examples/      # 可运行的 .pp 示例
├── ppdb/          # 嵌入式数据库（db_core / sql / kv / doc / cli + tests）
├── ppos/          # freestanding unikernel（net / tls / fs / json / mcp / wasm …）
├── tutorial/      # lang/（语言教程）+ os/（OS 教程）
├── tools/         # 工具脚本（ppdb-ref 等）
└── third_party/   # 只读第三方参考：uip-1.0/（网络栈）、eggos/（unikernel 参考）
```

### 现状

语言与编译器可用（`pp ir/run/build`），ppdb 独立分发测试全绿，ppos 在 QEMU 上跑通 app 模型 + MCP 工具；当前主线：uIP 1.0 胶水替换手写 TCP，解决 TLS 大响应健壮性。

- 路线图（唯一台账）：[`docs/roadmap.md`](docs/roadmap.md)
- 语言规范：[`pplang/spec.md`](pplang/spec.md)
- 进度实录：[`docs/progress.md`](docs/progress.md)

### 参考

- [LLVM Kaleidoscope 教程](https://llvm.org/docs/tutorial/MyFirstLanguageFrontend/index.html)
- [Writing an OS in Rust](https://os.phil-opp.com/)
- uIP（TCP/IP 栈，胶水集成）：`third_party/uip-1.0/`
- eggos（unikernel 参考）：`third_party/eggos/`

## <a id="english"></a>English

### What is this

pp-labs is a personal lab for systems software: a language (`pp`), a compiler, an embedded database, and a minimal unikernel, plus tutorials. Two threads run throughout: **teaching-friendly** and **LLM-friendly**.

### Layout

See the table above. Core artifacts: `pplang/spec.md` (authoritative spec), `docs/roadmap.md` (task ledger), `pplc/` (Rust + inkwell compiler), `ppdb/` (database), `ppos/` (freestanding demo), `tutorial/` (two tracks), `third_party/` (read-only references: uip-1.0, eggos).

### Status

The compiler is usable (`pp ir/run/build`), ppdb passes its full test suite standalone, ppos boots in QEMU with the app model + MCP tools. Current mainline: replacing the hand-written TCP stack with a uIP 1.0 glue layer to fix TLS large-response robustness. See [`docs/roadmap.md`](docs/roadmap.md).
